import AppKit
import Security
import SwiftUI
import os

private let claudeLog = Logger(subsystem: "app.islet.Islet", category: "claude")

/// Hook side: `Islet --claude-event` is what Claude Code runs. It reads the hook JSON
/// from stdin, rebroadcasts the useful fields as a distributed notification for the
/// running app, prints nothing and exits — a few milliseconds, never blocking Claude.
enum ClaudeHookRelay {
    static let notification = Notification.Name("app.islet.claude-event")

    static func run() {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        var info: [String: String] = [:]
        for key in ["hook_event_name", "session_id", "cwd", "message", "notification_type", "tool_name"] {
            if let v = json[key] as? String { info[key] = v }
        }
        if let input = json["tool_input"] as? [String: Any] {
            let detail =
                (input["file_path"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }
                ?? (input["description"] as? String)
                ?? (input["pattern"] as? String)
                ?? (input["url"] as? String).flatMap { URL(string: $0)?.host }
                ?? (input["command"] as? String)
            if let detail { info["tool_detail"] = String(detail.prefix(60)) }
        }
        DistributedNotificationCenter.default().postNotificationName(notification, object: nil, userInfo: info, deliverImmediately: true)
    }

    static let limitsNotification = Notification.Name("app.islet.claude-limits")

    /// Status line side: `Islet --claude-status`. Claude Code pipes its status JSON here
    /// after each API response; its `rate_limits` block carries the 5-hour and 7-day usage
    /// read from Anthropic's own response headers, so no extra request is ever made.
    /// Prints the status line Claude Code shows under the prompt.
    static func runStatusLine() {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        let limits = json["rate_limits"] as? [String: Any]
        var info: [String: String] = [:]
        var parts: [String] = []
        for (key, label) in [("five_hour", "session"), ("seven_day", "week")] {
            guard let w = limits?[key] as? [String: Any], let used = (w["used_percentage"] as? NSNumber)?.doubleValue else { continue }
            info["\(key).used"] = String(used)
            if let reset = (w["resets_at"] as? NSNumber)?.doubleValue { info["\(key).reset"] = String(reset) }
            parts.append("\(Int(used.rounded()))% \(label)")
        }
        if !info.isEmpty {
            DistributedNotificationCenter.default().postNotificationName(limitsNotification, object: nil, userInfo: info, deliverImmediately: true)
        }
        let model = (json["model"] as? [String: Any])?["display_name"] as? String
        print(([model].compactMap { $0 } + parts).joined(separator: " · "))
    }
}

/// App side: tracks Claude Code sessions from hook events and the account's rate
/// limits from Anthropic's usage endpoint.
final class ClaudeMonitor: ObservableObject {
    struct Session: Equatable {
        var project: String
        var working: Bool
        var waiting: Bool
        var updated: Date
        /// What Claude is doing right now, when it is running a tool.
        var activity: String?
        var promptStarted: Date?
        var lastRun: TimeInterval?
        var finished: Date?
    }

    struct Window: Equatable {
        var utilization: Double  // 0...100
        var resetsAt: Date?
        var length: TimeInterval

        /// Ahead of a steady pace through the window → slow down.
        var pace: Pace {
            if utilization >= 90 { return .limit }
            guard let resetsAt else { return .good }
            let elapsed = 1 - max(0, resetsAt.timeIntervalSinceNow) / length
            return utilization / 100 > elapsed + 0.12 && utilization > 25 ? .slowDown : .good
        }
    }

    enum Pace {
        case good, slowDown, limit
        var label: String { self == .good ? "On track" : self == .slowDown ? "Slow down" : "Near limit" }
        var tint: Color { self == .good ? .green : self == .slowDown ? .orange : .red }
    }

    enum UsageStatus: Equatable { case idle, loading, ok, noCredentials, denied, expired, failed(String) }

    static let tint = Color(red: 0.85, green: 0.47, blue: 0.34)  // Claude terracotta

    @Published private(set) var sessions: [String: Session] = [:]
    @Published private(set) var isWorking = false
    @Published private(set) var session: Window?
    @Published private(set) var weekly: Window?
    @Published private(set) var usageStatus: UsageStatus = .idle
    @Published private(set) var lastDone: (project: String, date: Date)?
    @Published private(set) var hooksInstalled = ClaudeHooks.isInstalled

    var onNotice: ((NoticeKind) -> Void)?

    private var lastFetch = Date.distantPast
    /// Last time Claude Code's status line reported limits; while recent, the web
    /// endpoint is left alone.
    private var lastStatusLine = Date.distantPast
    /// Earliest moment the usage endpoint may be called again (rate-limit backoff).
    /// Earliest moment the usage endpoint may be called again. Persisted, so relaunching
    /// Islet never calls an endpoint that asked it to wait.
    /// The last answer said the token was refused: read a fresh one next time.
    private var reloadTokenNext = false
    private var notBefore = Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: "claudeUsageNotBefore")) {
        didSet { UserDefaults.standard.set(notBefore.timeIntervalSince1970, forKey: "claudeUsageNotBefore") }
    }
    private var backoff: TimeInterval = 0
    private static let cacheKey = "claudeUsageCache"
    private static let cacheDateKey = "claudeUsageFetched"
    @Published private(set) var usageUpdated: Date?
    private var refreshTimer: Timer?
    /// Set when the user declines the keychain prompt: no more prompts until they retry.
    private var keychainBlocked = false
    private var alerted: Set<String> = []
    private let io = DispatchQueue(label: "islet.claude", qos: .utility)

    var workingProject: String? { sessions.values.filter(\.working).max { $0.updated < $1.updated }?.project }

    /// When Claude Code last reported anything, kept across launches: it decides whether
    /// Claude counts as in use next to the other assistants.
    private(set) var lastActive: Date? = {
        let t = UserDefaults.standard.double(forKey: "claudeLastActive")
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }() {
        didSet { UserDefaults.standard.set(lastActive?.timeIntervalSince1970 ?? 0, forKey: "claudeLastActive") }
    }

    /// The session worth showing: the most recent working one, else the most recent.
    var current: Session? {
        sessions.values.filter(\.working).max { $0.updated < $1.updated } ?? sessions.values.max { $0.updated < $1.updated }
    }

    /// One-line state, in Claude Code's own terms.
    static func describe(_ s: Session?) -> String {
        guard let s else { return "Idle" }
        if s.waiting { return "Waiting for you" }
        if s.working { return s.activity ?? "Thinking…" }
        return s.finished != nil ? "Done" : "Idle"
    }

    /// Tool name → what the user would call it.
    static func toolLabel(_ tool: String, detail: String?) -> String {
        let name: String
        switch tool {
        case "Bash": name = "Terminal"
        case "Read": name = "Reading"
        case "Edit", "MultiEdit", "Write", "NotebookEdit": name = "Editing"
        case "Grep", "Glob": name = "Searching"
        case "WebFetch", "WebSearch": name = "Web"
        case "Task", "Agent": name = "Subagent"
        case "TodoWrite": name = "Planning"
        default: name = tool.hasPrefix("mcp__") ? (tool.split(separator: "_").last.map(String.init) ?? "Tool") : tool
        }
        guard let detail, !detail.isEmpty else { return name }
        return "\(name) · \(detail)"
    }

    func start() {
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(received(_:)), name: ClaudeHookRelay.notification, object: nil, suspensionBehavior: .deliverImmediately)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(receivedLimits(_:)), name: ClaudeHookRelay.limitsNotification, object: nil,
            suspensionBehavior: .deliverImmediately)
        prefsChanged()
    }

    func prefsChanged() {
        hooksInstalled = ClaudeHooks.isInstalled
        let wanted = Prefs.bool(Prefs.claudeEnabled) && Prefs.bool(Prefs.claudeUsage)
        if wanted, refreshTimer == nil {
            loadCachedUsage()
            refreshUsage(force: false, minInterval: 290)
            // Rate limits move slowly; 5 minutes is plenty, and the endpoint is rate limited.
            // Every 10 minutes, but only while Claude has been used in the last hour.
            let t = Timer(timeInterval: 600, repeats: true) { [weak self] _ in
                guard let self, self.sessions.values.contains(where: { Date().timeIntervalSince($0.updated) < 3600 }) else { return }
                self.refreshUsage(force: false, minInterval: 590)
            }
            t.tolerance = 60
            RunLoop.main.add(t, forMode: .common)
            refreshTimer = t
        } else if !wanted {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
    }

    // MARK: Status line limits

    /// Limits pushed by Claude Code's status line: the primary, request-free source.
    @objc private func receivedLimits(_ note: Notification) {
        guard let info = note.userInfo as? [String: String] else { return }
        claudeLog.notice("limits received from the Claude Code status line")
        func window(_ key: String, _ length: TimeInterval) -> Window? {
            guard let used = info["\(key).used"].flatMap(Double.init) else { return nil }
            let reset = info["\(key).reset"].flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
            return Window(utilization: used, resetsAt: reset, length: length)
        }
        DispatchQueue.main.async { [self] in
            lastStatusLine = Date()
            withAnimation(Motion.content) {
                if let s = window("five_hour", 5 * 3600) { session = s }
                if let w = window("seven_day", 7 * 86400) { weekly = w }
            }
            usageUpdated = Date()
            usageStatus = .ok
            checkAlerts()
        }
    }

    // MARK: Hook events

    @objc private func received(_ note: Notification) {
        guard Prefs.bool(Prefs.claudeEnabled), let info = note.userInfo as? [String: String],
            let event = info["hook_event_name"]
        else { return }
        let id = info["session_id"] ?? "default"
        let project = info["cwd"].map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Claude"
        DispatchQueue.main.async { [self] in
            var s = sessions[id] ?? Session(project: project, working: false, waiting: false, updated: Date())
            s.project = project
            s.updated = Date()
            lastActive = s.updated
            switch event {
            case "UserPromptSubmit":
                s.working = true; s.waiting = false
                s.activity = nil
                s.promptStarted = Date()
                s.finished = nil
            case "PreToolUse":
                if !s.working { s.promptStarted = s.promptStarted ?? Date() }
                s.working = true; s.waiting = false
                s.activity = info["tool_name"].map { Self.toolLabel($0, detail: info["tool_detail"]) }
            case "PostToolUse":
                s.activity = nil
            case "PreCompact":
                s.activity = "Compacting context"
            case "Stop":
                s.lastRun = s.promptStarted.map { Date().timeIntervalSince($0) }
                s.finished = Date()
                s.activity = nil
                s.working = false; s.waiting = false
                lastDone = (project, Date())
                if shouldAnnounce { announce(.claudeDone(project: project)) }
                // A finished answer is the best moment to check the limits.
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.refreshUsage(force: false, minInterval: 120) }
            case "Notification":
                s.waiting = true
                let message = info["message"] ?? "Claude is waiting for you"
                if shouldAnnounce { announce(.claudeWaiting(project: project, message: message)) }
            case "SessionEnd":
                sessions[id] = nil
                updateWorking()
                return
            default:
                break
            }
            sessions[id] = s
            updateWorking()
        }
    }

    private func updateWorking() {
        // Drop sessions that went silent (crash, killed terminal).
        sessions = sessions.filter { $0.value.working ? Date().timeIntervalSince($0.value.updated) < 7200 : Date().timeIntervalSince($0.value.updated) < 86400 }
        let working = sessions.values.contains { $0.working }
        if working != isWorking { isWorking = working }
    }

    private func announce(_ kind: NoticeKind) {
        if Prefs.bool(Prefs.claudeSound) { NSSound(named: "Tink")?.play() }
        onNotice?(kind)
    }

    /// Only interrupt when the user is elsewhere (that is the point of the notch).
    private var shouldAnnounce: Bool {
        guard Prefs.bool(Prefs.claudeOnlyWhenAway) else { return true }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let claudeHosts: Set<String> = [
            "com.anthropic.claudefordesktop", "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
            "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed",
        ]
        return !claudeHosts.contains(front)
    }

    // MARK: Usage limits

    /// Asks the keychain again after the user declined (or the token went stale).
    func retryUsage() {
        keychainBlocked = false
        notBefore = .distantPast
        refreshUsage(force: true, reloadToken: true)
    }

    func refreshUsage(force: Bool, minInterval: TimeInterval = 120, reloadToken: Bool = false) {
        guard Prefs.bool(Prefs.claudeEnabled), Prefs.bool(Prefs.claudeUsage), !keychainBlocked else { return }
        guard Date() >= notBefore else {
            if session == nil { usageStatus = .failed("Anthropic asked to wait until \(Format.time.string(from: notBefore))") }
            return
        }
        // Fallback only: the status line already delivers fresh limits for free.
        guard Date().timeIntervalSince(lastStatusLine) > 900 else { return }
        guard force || Date().timeIntervalSince(lastFetch) > minInterval else { return }
        lastFetch = Date()
        let reloadToken = reloadToken || reloadTokenNext
        reloadTokenNext = false
        if session == nil { usageStatus = .loading }
        io.async { [weak self] in
            let token: String
            switch ClaudeCredentials.token(reload: reloadToken) {
            case .token(let t):
                token = t
            case .missing:
                DispatchQueue.main.async { self?.usageStatus = .noCredentials }
                return
            case .denied:
                DispatchQueue.main.async {
                    self?.keychainBlocked = true
                    self?.usageStatus = .denied
                }
                return
            }
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 15
            URLSession.shared.dataTask(with: request) { data, response, _ in
                let http = response as? HTTPURLResponse
                let code = http?.statusCode ?? 0
                let retryAfter = (http?.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
                DispatchQueue.main.async { self?.applyUsage(data: data, status: code, retried: reloadToken, retryAfter: retryAfter) }
            }.resume()
        }
    }

    private func applyUsage(data: Data?, status: Int, retried: Bool, retryAfter: TimeInterval?) {
        claudeLog.notice("usage endpoint answered \(status, privacy: .public), retry-after \(retryAfter ?? -1, privacy: .public)")
        if status == 429 {
            // Back off: honour Retry-After, else 5, 10, 20… up to 30 minutes. Keep showing
            // the last known values meanwhile instead of an error.
            backoff = max(retryAfter ?? 0, backoff == 0 ? 300 : min(backoff * 2, 1800))
            notBefore = Date().addingTimeInterval(backoff)
            if session == nil { usageStatus = .failed("Anthropic asked to wait until \(Format.time.string(from: notBefore))") }
            return
        }
        if status == 401 || status == 403 {
            // Claude Code may have rotated its token since we read it. Read it again on the
            // next attempt, a few minutes later: an immediate retry gets Islet throttled for an hour.
            if retried {
                usageStatus = .expired
            } else {
                reloadTokenNext = true
                notBefore = Date().addingTimeInterval(300)
                if session == nil { usageStatus = .failed("Claude Code’s sign-in changed, retrying at \(Format.time.string(from: notBefore))") }
            }
            return
        }
        guard status == 200, let data, let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            usageStatus = .failed(status == 0 ? "Offline" : "Error \(status)")
            return
        }
        backoff = 0
        UserDefaults.standard.set(data, forKey: Self.cacheKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.cacheDateKey)
        apply(json, fetched: Date())
        checkAlerts()
    }

    private func apply(_ json: [String: Any], fetched: Date) {
        withAnimation(Motion.content) {
            session = Self.window(json["five_hour"], length: 5 * 3600)
            weekly = Self.window(json["seven_day"], length: 7 * 86400)
        }
        usageUpdated = fetched
        usageStatus = .ok
    }

    /// Last answer from a previous run, so a relaunch shows the limits without a request.
    private func loadCachedUsage() {
        let t = UserDefaults.standard.double(forKey: Self.cacheDateKey)
        guard t > 0, let data = UserDefaults.standard.data(forKey: Self.cacheKey),
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }
        let fetched = Date(timeIntervalSince1970: t)
        guard Date().timeIntervalSince(fetched) < 6 * 3600 else { return }
        lastFetch = fetched
        apply(json, fetched: fetched)
    }

    private static func window(_ any: Any?, length: TimeInterval) -> Window? {
        guard let d = any as? [String: Any] else { return nil }
        let u = (d["utilization"] as? NSNumber)?.doubleValue ?? 0
        var reset: Date?
        if let s = d["resets_at"] as? String {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            reset = f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
        }
        return Window(utilization: u, resetsAt: reset, length: length)
    }

    private func checkAlerts() {
        guard Prefs.bool(Prefs.claudeUsageAlerts) else { return }
        for (name, w) in [("session", session), ("week", weekly)] {
            guard let w else { continue }
            for threshold in [80, 95] where Int(w.utilization) >= threshold {
                let key = "\(name)-\(threshold)-\(w.resetsAt?.timeIntervalSince1970 ?? 0)"
                if alerted.insert(key).inserted { onNotice?(.claudeUsage(percent: Int(w.utilization), window: name)) }
                break
            }
        }
    }

    func loadPreview(working: Bool, limits: Bool = true) {
        sessions = [
            "preview": Session(
                project: "Islet", working: working, waiting: false, updated: Date(),
                activity: working ? "Terminal · swift build" : nil, promptStarted: Date().addingTimeInterval(-84),
                lastRun: working ? nil : 192, finished: working ? nil : Date().addingTimeInterval(-120))
        ]
        isWorking = working
        session = limits ? Window(utilization: 45, resetsAt: Date().addingTimeInterval(55 * 60), length: 5 * 3600) : nil
        weekly = limits ? Window(utilization: 42, resetsAt: Date().addingTimeInterval(4 * 86400 + 19 * 3600), length: 7 * 86400) : nil
        usageStatus = .ok
        hooksInstalled = true
    }

    func installHooks() throws { try ClaudeHooks.install(); hooksInstalled = ClaudeHooks.isInstalled }
    func removeHooks() throws { try ClaudeHooks.uninstall(); hooksInstalled = ClaudeHooks.isInstalled }
}

/// Reads the OAuth token Claude Code keeps in the login keychain. The token is cached in
/// memory until it expires, so macOS asks at most once per token instead of on every
/// refresh. Used for the usage request and nothing else. Only touched on the monitor's
/// serial queue.
enum ClaudeCredentials {
    enum Read { case token(String), missing, denied }

    private static var cached: (token: String, expires: Date)?

    static func token(reload: Bool) -> Read {
        if !reload, let c = cached, c.expires.timeIntervalSinceNow > 60 { return .token(c.token) }
        cached = nil
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &item) {
        case errSecSuccess: break
        case errSecItemNotFound: return .missing
        default: return .denied  // declined, wrong password or no UI allowed
        }
        guard let data = item as? Data,
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let oauth = json["claudeAiOauth"] as? [String: Any],
            let token = oauth["accessToken"] as? String
        else { return .missing }
        // Claude Code stores `expiresAt` in milliseconds since 1970.
        var expires = Date().addingTimeInterval(3600)
        if let ms = (oauth["expiresAt"] as? NSNumber)?.doubleValue {
            expires = Date(timeIntervalSince1970: ms > 1e12 ? ms / 1000 : ms)
        }
        cached = (token, expires)
        return .token(token)
    }
}

/// Adds or removes Islet's hooks in ~/.claude/settings.json, leaving every other
/// setting and hook untouched. A backup is written next to it first.
enum ClaudeHooks {
    static let events = ["UserPromptSubmit", "PreToolUse", "PostToolUse", "PreCompact", "Stop", "Notification", "SessionEnd"]
    /// Tool events take a matcher; "*" means every tool.
    static let toolEvents: Set<String> = ["PreToolUse", "PostToolUse"]
    static let marker = "--claude-event"
    static let statusMarker = "--claude-status"
    static var settingsURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json") }

    private static var executable: String { Bundle.main.executablePath ?? "/Applications/Islet.app/Contents/MacOS/Islet" }
    static var command: String { "'\(executable)' \(marker)" }
    static var statusCommand: String { "'\(executable)' \(statusMarker)" }

    static var isInstalled: Bool { isInstalled(at: settingsURL) }

    static func isInstalled(at url: URL) -> Bool {
        guard let settings = try? load(url), let hooks = settings["hooks"] as? [String: Any] else { return false }
        return events.allSatisfy { contains(hooks[$0]) } && (ownsStatusLine(settings) || settings["statusLine"] != nil)
    }

    private static func contains(_ any: Any?) -> Bool {
        guard let groups = any as? [[String: Any]] else { return false }
        return groups.contains { group in
            (group["hooks"] as? [[String: Any]])?.contains { ($0["command"] as? String)?.contains(marker) == true } == true
        }
    }

    /// Whether Claude Code's status line is Islet's (a user's own one is never replaced).
    static func ownsStatusLine(_ settings: [String: Any]) -> Bool {
        ((settings["statusLine"] as? [String: Any])?["command"] as? String)?.contains(statusMarker) == true
    }

    static func ownsStatusLine(at url: URL = settingsURL) -> Bool { (try? load(url)).map(ownsStatusLine) ?? false }

    private static func load(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private static func save(_ settings: [String: Any], to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: url.path) {
            let backup = url.appendingPathExtension("islet-backup")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: url, to: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }

    static func install(at url: URL = settingsURL, command: String = command, statusCommand: String = statusCommand) throws {
        var settings = try load(url)
        if settings["statusLine"] == nil || ownsStatusLine(settings) {
            settings["statusLine"] = ["type": "command", "command": statusCommand]
        }
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in events {
            var groups = stripped(hooks[event])
            var group: [String: Any] = ["hooks": [["type": "command", "command": command, "timeout": 5]]]
            if toolEvents.contains(event) { group["matcher"] = "*" }
            groups.append(group)
            hooks[event] = groups
        }
        settings["hooks"] = hooks
        try save(settings, to: url)
    }

    static func uninstall(at url: URL = settingsURL) throws {
        var settings = try load(url)
        if ownsStatusLine(settings) { settings["statusLine"] = nil }
        guard var hooks = settings["hooks"] as? [String: Any] else {
            try save(settings, to: url)
            return
        }
        for event in events {
            let groups = stripped(hooks[event])
            hooks[event] = groups.isEmpty ? nil : groups
        }
        settings["hooks"] = hooks.isEmpty ? nil : hooks
        try save(settings, to: url)
    }

    /// The event's hook groups without Islet's entries.
    private static func stripped(_ any: Any?) -> [[String: Any]] {
        (any as? [[String: Any]] ?? []).compactMap { group in
            var g = group
            let kept = (group["hooks"] as? [[String: Any]] ?? []).filter { ($0["command"] as? String)?.contains(marker) != true }
            if kept.isEmpty { return nil }
            g["hooks"] = kept
            return g
        }
    }
}
