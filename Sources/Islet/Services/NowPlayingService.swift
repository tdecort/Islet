import AppKit
import SwiftUI

/// Now Playing for Music and Spotify.
///
/// Both players broadcast a distributed notification on every play/pause/track change,
/// so nothing is polled. Details (position, artwork, shuffle) come from one AppleScript
/// round trip per change, run on a private serial queue, and only ever against a player
/// that is already running (AppleScript would otherwise launch it).
final class NowPlayingService: ObservableObject {
    enum Source: String, CaseIterable {
        case music = "com.apple.Music"
        case spotify = "com.spotify.client"
        /// Anything the system Now Playing service reports from another app: YouTube in a
        /// browser, podcasts… (read through `MediaRemoteBridge`).
        case web = "web"

        var name: String {
            switch self {
            case .music: return "Music"
            case .spotify: return "Spotify"
            case .web: return "Web"
            }
        }

        var prefKey: String {
            switch self {
            case .music: return Prefs.sourceMusic
            case .spotify: return Prefs.sourceSpotify
            case .web: return Prefs.sourceWeb
            }
        }

        /// AppleScript-driven players only; the web source has no app of its own to script.
        var isRunning: Bool { self != .web && !NSRunningApplication.runningApplications(withBundleIdentifier: rawValue).isEmpty }
        var isInstalled: Bool { self != .web && NSWorkspace.shared.urlForApplication(withBundleIdentifier: rawValue) != nil }
        var appURL: URL? { self == .web ? nil : NSWorkspace.shared.urlForApplication(withBundleIdentifier: rawValue) }

        fileprivate var stateScript: String {
            switch self {
            case .music:
                return """
                    tell application id "com.apple.Music"
                        if player state is stopped then return "STOPPED"
                        set t to current track
                        return {name of t, artist of t, album of t, duration of t, player position, (player state as string), shuffle enabled, ""}
                    end tell
                    """
            case .spotify:
                return """
                    tell application id "com.spotify.client"
                        if player state is stopped then return "STOPPED"
                        set t to current track
                        return {name of t, artist of t, album of t, (duration of t) / 1000, player position, (player state as string), shuffling, artwork url of t}
                    end tell
                    """
            case .web:
                return ""
            }
        }
    }

    struct Track: Equatable {
        var title: String
        var artist: String
        var album: String
        var duration: Double
    }

    @Published private(set) var track: Track?
    @Published private(set) var isPlaying = false
    @Published private(set) var artwork: NSImage?
    @Published private(set) var accent: Color = .white
    @Published private(set) var shuffle = false
    @Published private(set) var source: Source?
    @Published private(set) var hasActivity = false

    private var position: Double = 0
    private let bridge = MediaRemoteBridge()
    /// The app behind the web source (Firefox, Safari, Chrome…).
    private var webBundleID: String?
    private var positionDate = Date()
    private var artworkKey: String?
    private var idleWork: DispatchWorkItem?

    private let queue = DispatchQueue(label: "islet.applescript", qos: .userInitiated)
    private var scripts: [String: NSAppleScript] = [:]  // only touched on `queue`

    func elapsed(at date: Date = Date()) -> Double {
        guard let track else { return 0 }
        let e = position + (isPlaying ? date.timeIntervalSince(positionDate) : 0)
        return min(max(0, e), track.duration)
    }

    // MARK: Lifecycle

    func start() {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(
            self, selector: #selector(musicChanged), name: .init("com.apple.Music.playerInfo"), object: nil, suspensionBehavior: .deliverImmediately)
        dnc.addObserver(
            self, selector: #selector(spotifyChanged), name: .init("com.spotify.client.PlaybackStateChanged"), object: nil,
            suspensionBehavior: .deliverImmediately)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appTerminated(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        Source.allCases.filter(\.isRunning).forEach(refresh)
        bridge.onUpdate = { [weak self] in self?.applyWeb($0) }
        if Prefs.bool(Prefs.sourceWeb) { bridge.start() }
    }

    // MARK: System Now Playing (web)

    private static let nativeBundles: Set<String> = ["com.apple.Music", "com.spotify.client"]

    private func applyWeb(_ p: [String: Any]) {
        guard Prefs.bool(Prefs.sourceWeb) else { return }
        guard p["state"] as? String == "info", let bundle = p["bundle"] as? String, !Self.nativeBundles.contains(bundle),
            let title = p["title"] as? String, !title.isEmpty
        else {
            if source == .web { clear() }
            return
        }
        let rate = (p["rate"] as? NSNumber)?.doubleValue ?? 0
        let playing = rate > 0
        // Spotify keeps priority while it plays; a paused web player never steals a playing one.
        if source == .spotify, isPlaying { return }
        if let current = source, current != .web, isPlaying, !playing { return }

        let t = Track(
            title: title, artist: p["artist"] as? String ?? Self.appName(bundle), album: p["album"] as? String ?? "",
            duration: max(1, (p["duration"] as? NSNumber)?.doubleValue ?? 1))
        source = .web
        webBundleID = bundle
        if track != t { track = t }
        isPlaying = playing
        var elapsed = (p["elapsed"] as? NSNumber)?.doubleValue ?? 0
        if playing, let stamp = (p["timestamp"] as? NSNumber)?.doubleValue {
            elapsed += Date().timeIntervalSince1970 - stamp
        }
        position = elapsed
        positionDate = Date()
        shuffle = false
        if !hasActivity { hasActivity = true }
        if let b64 = p["artwork"] as? String, let data = Data(base64Encoded: b64), let image = NSImage(data: data) {
            artworkKey = "web|\(t.title)|\(t.artist)"
            withAnimation(Motion.content) {
                artwork = image
                accent = Self.accentColor(image)
            }
        } else if artworkKey?.hasPrefix("web|\(t.title)|") != true {
            // Browsers (Firefox at least) hand macOS no artwork: look the video up instead.
            let key = "web|\(t.title)|\(t.artist)"
            artworkKey = key
            artwork = nil
            accent = .white
            fetchVideoThumbnail(title: t.title, channel: t.artist, key: key)
        }
        idleWork?.cancel()
        if !playing {
            let work = DispatchWorkItem { [weak self] in self?.clear() }
            idleWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 300, execute: work)
        }
    }

    /// Finds the video on YouTube from its title and channel and loads its thumbnail.
    /// The first result is only trusted when its title matches, so non-YouTube media
    /// get no picture rather than a wrong one.
    private func fetchVideoThumbnail(title: String, channel: String, key: String) {
        var c = URLComponents(string: "https://www.youtube.com/results")!
        c.queryItems = [.init(name: "search_query", value: "\(title) \(channel)")]
        var request = URLRequest(url: c.url!)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let data, let html = String(data: data, encoding: .utf8),
                let start = html.range(of: #""videoRenderer":{"videoId":""#)
            else { return }
            let id = String(html[start.upperBound...].prefix(11))
            let nearby = String(html[start.upperBound...].prefix(4000))
            let wanted = String(Self.normalized(title).prefix(18))
            guard !wanted.isEmpty, Self.normalized(nearby).contains(wanted),
                let thumb = URL(string: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg")
            else { return }
            URLSession.shared.dataTask(with: thumb) { data, _, _ in
                guard let data, let image = NSImage(data: data) else { return }
                DispatchQueue.main.async {
                    guard let self, self.artworkKey == key else { return }
                    withAnimation(Motion.content) {
                        self.artwork = image
                        self.accent = Self.accentColor(image)
                    }
                }
            }.resume()
        }.resume()
    }

    /// Lowercased letters and digits only, for loose title matching.
    private static func normalized(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(Character.init))
    }

    private static func appName(_ bundle: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? "Web"
    }

    @objc private func musicChanged() { refresh(.music) }
    @objc private func spotifyChanged() { refresh(.spotify) }

    @objc private func appTerminated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
            app.bundleIdentifier == source?.rawValue
        else { return }
        clear()
    }

    /// Re-read position (seeks made inside the player don't always broadcast).
    func resync() {
        if let source { refresh(source) }
    }

    func refresh(_ src: Source) {
        guard Prefs.bool(src.prefKey), src.isRunning else { return }
        queue.async { [weak self] in
            guard let self else { return }
            let result = self.run(src.stateScript, cacheKey: "state.\(src.rawValue)")
            DispatchQueue.main.async { self.apply(result, from: src) }
        }
    }

    // MARK: Parsing

    private func apply(_ d: NSAppleEventDescriptor?, from src: Source) {
        guard let d, d.numberOfItems >= 7 else {
            if source == src || source == nil { clear() }
            return
        }
        let playing = d.atIndex(6)?.stringValue == "playing"
        // Prefer whichever player is actually playing.
        if let current = source, current != src, isPlaying, !playing { return }

        let t = Track(
            title: d.atIndex(1)?.stringValue ?? "",
            artist: d.atIndex(2)?.stringValue ?? "",
            album: d.atIndex(3)?.stringValue ?? "",
            duration: max(1, d.atIndex(4)?.doubleValue ?? 1)
        )
        source = src
        if track != t { track = t }
        isPlaying = playing
        position = d.atIndex(5)?.doubleValue ?? 0
        positionDate = Date()
        shuffle = d.atIndex(7)?.booleanValue ?? false
        if !hasActivity { hasActivity = true }

        let key = "\(src.rawValue)|\(t.title)|\(t.artist)|\(t.album)"
        if key != artworkKey {
            artworkKey = key
            loadArtwork(src, url: d.atIndex(8)?.stringValue, key: key)
        }

        // A paused player stays a live activity for a while, like on iPhone.
        idleWork?.cancel()
        if !playing {
            let work = DispatchWorkItem { [weak self] in self?.clear() }
            idleWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 300, execute: work)
        }
    }

    private func clear() {
        idleWork?.cancel()
        track = nil
        isPlaying = false
        artwork = nil
        artworkKey = nil
        source = nil
        accent = .white
        if hasActivity { hasActivity = false }
    }

    private func loadArtwork(_ src: Source, url: String?, key: String) {
        let finish: (NSImage?) -> Void = { [weak self] image in
            DispatchQueue.main.async {
                guard let self, self.artworkKey == key else { return }
                withAnimation(Motion.content) {
                    self.artwork = image
                    self.accent = image.map(Self.accentColor) ?? .white
                }
            }
        }
        switch src {
        case .music:
            queue.async { [weak self] in
                let d = self?.run("tell application id \"com.apple.Music\" to get raw data of artwork 1 of current track", cacheKey: "art.music")
                finish(d.flatMap { NSImage(data: $0.data) })
            }
        case .spotify:
            guard let s = url, let u = URL(string: s) else { finish(nil); return }
            URLSession.shared.dataTask(with: u) { data, _, _ in finish(data.flatMap(NSImage.init(data:))) }.resume()
        case .web:
            break  // artwork arrives with the system Now Playing update itself
        }
    }

    /// Average colour of the artwork, lifted so it reads on black.
    static func accentColor(_ image: NSImage) -> Color {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return .white }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard
            let ctx = CGContext(
                data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return .white }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let c = NSColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.usingColorSpace(.deviceRGB)?.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        if s < 0.12 { return Color(white: 0.92) }
        return Color(hue: h, saturation: min(1, s * 1.15 + 0.1), brightness: max(b, 0.82))
    }

    func loadPreview(_ t: Track, artwork: NSImage?, playing: Bool, elapsed: Double) {
        track = t; isPlaying = playing; position = elapsed; positionDate = Date(); source = .music
        self.artwork = artwork; accent = artwork.map(Self.accentColor) ?? .white; hasActivity = true
    }

    // MARK: Controls

    func playPause() {
        isPlaying.toggle()  // optimistic, the broadcast confirms it
        if !isPlaying { position = elapsed() } else { positionDate = Date() }
        if source == .web { bridge.send("toggle"); return }
        command("playpause")
    }

    func next() { source == .web ? bridge.send("next") : command("next track") }
    func previous() { source == .web ? bridge.send("prev") : command("previous track") }

    func seek(to fraction: Double) {
        guard let track else { return }
        let s = max(0, min(1, fraction)) * track.duration
        position = s
        positionDate = Date()
        objectWillChange.send()
        if source == .web { bridge.send("seek \(String(format: "%.2f", s))"); return }
        command("set player position to \(String(format: "%.2f", s))")
    }

    func toggleShuffle() {
        guard let source, source != .web else { return }
        shuffle.toggle()
        command(source == .music ? "set shuffle enabled to not shuffle enabled" : "set shuffling to not shuffling")
    }

    func openPlayer() {
        let bundle = source == .web ? webBundleID : source?.rawValue
        guard let bundle, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    private func command(_ verb: String) {
        guard let source, source.isRunning else { return }
        let script = "tell application id \"\(source.rawValue)\" to \(verb)"
        queue.async { [weak self] in
            _ = self?.run(script, cacheKey: script)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self?.refresh(source) }
        }
    }

    private func run(_ source: String, cacheKey: String) -> NSAppleEventDescriptor? {
        let script: NSAppleScript
        if let cached = scripts[cacheKey] {
            script = cached
        } else {
            guard let s = NSAppleScript(source: source) else { return nil }
            var error: NSDictionary?
            guard s.compileAndReturnError(&error) else { return nil }
            scripts[cacheKey] = s
            script = s
        }
        var error: NSDictionary?
        let out = script.executeAndReturnError(&error)
        return error == nil ? out : nil
    }
}
