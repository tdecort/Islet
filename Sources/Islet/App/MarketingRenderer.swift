import AppKit
import SwiftUI

/// `Islet --marketing <dir>` renders the feature showcase: every scene a customer should
/// see, on a macOS-like desktop, with fictional demo content.
@MainActor
enum MarketingRenderer {
    static func run(into dir: URL) {
        SnapshotRenderer.isRendering = true
        SnapshotRenderer.callStill = callStill()
        Format.locale = Locale(identifier: "en_US")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let services = Services()
        let model = IslandModel(services: services)
        let notch = CGSize(width: 179, height: 32)
        model.setScreen(notch: notch, detached: false)
        services.battery.loadPreview(percent: 82, charging: false)

        let track = NowPlayingService.Track(title: "Midnight Drive", artist: "Nova Lane", album: "Neon Coast", duration: 214)
        services.nowPlaying.loadPreview(track, artwork: albumArt(), playing: true, elapsed: 74)
        UserDefaults.standard.set(false, forKey: Prefs.claudeUsage)  // demo data only, no network

        func shot(_ name: String, notchOnScreen: Bool = true, _ configure: () -> Void) {
            configure()
            let view = ZStack(alignment: .top) {
                Desktop(notch: notchOnScreen)
                IslandRootView(model: model)
                    .padding(.top, model.detached ? 38 : 0)
            }
            .frame(width: 960, height: 280)
            .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let cg = renderer.cgImage,
                let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
            else {
                print("failed \(name)")
                return
            }
            try? png.write(to: dir.appendingPathComponent("\(name).png"))
            print("wrote \(name).png")
        }

        // Feel
        shot("01-hover-bounce") {
            UserDefaults.standard.set(false, forKey: Prefs.nowPlayingEnabled)
            model.preview(hovering: true, bumped: true)
        }
        UserDefaults.standard.removeObject(forKey: Prefs.nowPlayingEnabled)

        // Music
        shot("02-music-compact") { model.preview() }
        shot("03-music-player") { model.preview(expanded: .nowPlaying) }

        // Claude
        shot("04-claude-and-music") {
            services.claude.loadPreview(working: true)
            model.preview()
        }
        shot("05-claude-working") { model.preview(expanded: .claude) }
        shot("06-claude-done") {
            services.claude.loadPreview(working: false)
            model.preview(transient: .notice(Notice(kind: .claudeDone(project: "Islet"))))
        }
        shot("07-claude-waiting") {
            model.preview(transient: .notice(Notice(kind: .claudeWaiting(project: "Islet", message: "Claude is waiting for you"))))
        }

        shot("07b-all-assistants") {
            UserDefaults.standard.set(true, forKey: Prefs.aiCodex)
            UserDefaults.standard.set(true, forKey: Prefs.aiGemini)
            services.claude.loadPreview(working: true)
            services.codex.loadPreview(AgentState(
                name: "Codex", project: "website", working: true, activity: "Editing", started: Date().addingTimeInterval(-95),
                limits: [.init(label: "Week", utilization: 38, resetsAt: Date().addingTimeInterval(4 * 86400))]))
            services.gemini.loadPreview(AgentState(name: "Gemini", project: "api", finished: Date().addingTimeInterval(-300)))
            model.preview(expanded: .claude)
        }

        // Calls
        shot("08-call-compact") {
            for key in [Prefs.aiCodex, Prefs.aiGemini] { UserDefaults.standard.removeObject(forKey: key) }
            services.claude.loadPreview(working: false, limits: false)
            services.call.loadPreview(camera: true, muted: false)
            model.preview()
        }
        shot("09-call-video") { model.preview(expanded: .call) }
        shot("10-call-pinned") {
            model.preview()
            model.toggleVideoPin()
            model.preview()
        }

        // System
        shot("11-volume") {
            model.toggleVideoPin()
            UserDefaults.standard.set(false, forKey: Prefs.callEnabled)
            model.preview(transient: .hud(.volume, 0.62, muted: false))
        }
        shot("12-brightness") { model.preview(transient: .hud(.brightness, 0.8, muted: false)) }
        shot("13-do-not-disturb-on") {
            model.preview(transient: .notice(Notice(kind: .focus(name: "Do Not Disturb", symbol: "moon.fill", tint: .indigo, active: true))))
        }
        shot("14-do-not-disturb-off") {
            model.preview(transient: .notice(Notice(kind: .focus(name: "Do Not Disturb", symbol: "moon.fill", tint: .indigo, active: false))))
        }
        shot("15-airpods") {
            model.preview(
                transient: .notice(
                    Notice(kind: .deviceConnected(name: "AirPods Pro", symbol: "airpodspro", battery: DeviceBattery(left: 92, right: 88, caseLevel: 70)))))
        }
        shot("16-charging") { model.preview(transient: .notice(Notice(kind: .charging(82)))) }
        // Paused music has left the folded island: only the charging bolt stays.
        UserDefaults.standard.set(false, forKey: Prefs.nowPlayingEnabled)
        shot("16b-charging-idle") {
            services.claude.loadPreview(working: false, limits: false)
            services.battery.loadPreview(percent: 64, charging: true)
            model.preview()
        }
        shot("16c-charging-and-claude") {
            services.claude.loadPreview(working: true, limits: false)
            model.preview()
        }
        services.battery.loadPreview(percent: 82, charging: false)
        UserDefaults.standard.removeObject(forKey: Prefs.nowPlayingEnabled)
        shot("17-low-battery") { model.preview(transient: .notice(Notice(kind: .lowBattery(18)))) }
        shot("18-unlock") { model.preview(transient: .notice(Notice(kind: .unlocked))) }

        // Day
        let today = Calendar.current.startOfDay(for: Date())
        func at(_ h: Int, _ m: Int) -> Date { today.addingTimeInterval(TimeInterval(h * 3600 + m * 60)) }
        services.calendar.loadPreview([
            .init(id: "1", title: "Product sync", start: at(10, 0), end: at(10, 30), tint: .purple, location: "Atlas Room"),
            .init(id: "2", title: "Lunch with Leah", start: at(12, 30), end: at(13, 30), tint: .green, location: nil),
            .init(id: "3", title: "Design review", start: at(15, 0), end: at(16, 0), tint: .orange, location: "Zoom"),
        ])
        shot("19-calendar") { model.preview(expanded: .calendar) }
        shot("20-event-reminder") {
            model.preview(transient: .notice(Notice(kind: .event(title: "Design review", minutes: 5, tint: .orange))))
        }
        let days = (1...5).map { i in
            WeatherService.Day(
                id: "\(i)", date: Date().addingTimeInterval(Double(i) * 86400), code: [2, 0, 3, 61, 1][i - 1],
                high: [24, 27, 25, 21, 26][i - 1], low: 14)
        }
        services.weather.loadPreview(.init(place: "San Francisco", temperature: 22, code: 2, isDay: true, high: 24, low: 13, days: days))
        shot("21-weather") { model.preview(expanded: .weather) }

        // Focus timer
        shot("22-timer-compact") {
            services.flow.start()
            UserDefaults.standard.set(false, forKey: Prefs.nowPlayingEnabled)
            model.preview()
        }
        shot("23-timer") { model.preview(expanded: .flow) }
        UserDefaults.standard.removeObject(forKey: Prefs.nowPlayingEnabled)

        // Files
        shot("24-shelf") {
            services.flow.reset()
            services.shelf.add(demoFiles())
            model.preview(expanded: .shelf)
        }
        shot("25-drag-and-drop") {
            services.shelf.clear()
            model.preview(expanded: .shelf)
            model.setDropTargeting(true)
            model.dragMoved(toOffset: -80)
        }

        // Swipe previews
        shot("26-swipe-glance") {
            model.dragMoved(toOffset: nil)
            model.setDropTargeting(false)
            model.preview()
            for _ in 0..<10 where model.glance != .weather { model.swipe(.left) }
            model.preview()
        }

        // Island style, for Macs without a notch
        shot("27-island-mode", notchOnScreen: false) {
            model.setScreen(notch: CGSize(width: 100, height: 32), detached: true, topInset: 0)
            model.swipe(.up)
            model.preview()
        }
        shot("28-island-mode-player", notchOnScreen: false) { model.preview(expanded: .nowPlaying) }

        // App icon
        let icon = ImageRenderer(content: AppIcon().frame(width: 1024, height: 1024))
        icon.scale = 0.5
        if let cg = icon.cgImage, let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
            try? png.write(to: dir.appendingPathComponent("00-icon.png"))
        }

        services.shelf.clear()
        for key in [Prefs.claudeUsage, Prefs.callEnabled, Prefs.aiCodex, Prefs.aiGemini] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    // MARK: Demo content (fictional)

    private static func albumArt() -> NSImage {
        let view = ZStack {
            LinearGradient(
                colors: [Color(red: 0.98, green: 0.36, blue: 0.47), Color(red: 0.36, green: 0.17, blue: 0.62)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(Color(red: 1, green: 0.78, blue: 0.4)).frame(width: 90).offset(y: 18)
            VStack(spacing: 7) {
                ForEach(0..<5, id: \.self) { i in
                    Capsule().fill(Color(red: 0.2, green: 0.08, blue: 0.4).opacity(0.85)).frame(width: 200, height: 5)
                        .offset(x: i.isMultiple(of: 2) ? -8 : 8)
                }
            }
            .offset(y: 62)
        }
        .frame(width: 200, height: 200)
        return ImageRenderer(content: view).nsImage ?? NSImage()
    }

    private static func callStill() -> NSImage {
        let view = ZStack {
            LinearGradient(
                colors: [Color(red: 0.32, green: 0.45, blue: 0.62), Color(red: 0.14, green: 0.2, blue: 0.3)],
                startPoint: .top, endPoint: .bottom)
            Circle().fill(Color(red: 0.93, green: 0.78, blue: 0.66)).frame(width: 70).offset(y: -18)
            Ellipse().fill(Color(red: 0.86, green: 0.42, blue: 0.36)).frame(width: 170, height: 110).offset(y: 70)
        }
        .frame(width: 320, height: 200)
        return ImageRenderer(content: view).nsImage ?? NSImage()
    }

    private static func demoFiles() -> [URL] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("IsletDemo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return ["Annual Report.pdf", "Vacation.jpg", "Keynote.key", "Budget.xlsx"].map { name in
            let url = dir.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: Data()) }
            return url
        }
    }
}

/// A macOS-like desktop: soft wallpaper, translucent menu bar, and the camera notch.
private struct Desktop: View {
    let notch: Bool

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(
                colors: [Color(red: 0.13, green: 0.2, blue: 0.45), Color(red: 0.42, green: 0.25, blue: 0.62), Color(red: 0.95, green: 0.55, blue: 0.45)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [Color(red: 1, green: 0.7, blue: 0.55).opacity(0.55), .clear], center: .bottomTrailing, startRadius: 10, endRadius: 520)
            RadialGradient(colors: [Color(red: 0.3, green: 0.55, blue: 1).opacity(0.45), .clear], center: .topLeading, startRadius: 10, endRadius: 480)
            Rectangle().fill(.black.opacity(0.18)).frame(height: 32)
            HStack(spacing: 18) {
                Image(systemName: "apple.logo").font(.system(size: 14, weight: .semibold))
                Text("Finder").font(.system(size: 13, weight: .bold))
                ForEach(["File", "Edit", "View", "Go"], id: \.self) { Text($0).font(.system(size: 13, weight: .medium)) }
                Spacer()
                ForEach(["wifi", "battery.75percent", "magnifyingglass", "switch.2"], id: \.self) {
                    Image(systemName: $0).font(.system(size: 13, weight: .medium))
                }
                Text("Mon Oct 26  2:30 PM").font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 16)
            .frame(height: 32)
            if notch {
                UnevenRoundedRectangle(bottomLeadingRadius: 9, bottomTrailingRadius: 9, style: .continuous)
                    .fill(.black).frame(width: 179, height: 32)
            }
        }
    }
}
