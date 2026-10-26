import ApplicationServices
import CoreBluetooth
import CoreLocation
import EventKit
import ServiceManagement
import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, display, battery, connectivity, focus, nowPlaying, claude, calendar, weather, flow, shelf, permissions, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .display: return "Sound & Brightness"
        case .battery: return "Battery"
        case .connectivity: return "Audio Devices"
        case .focus: return "Focus"
        case .nowPlaying: return "Now Playing"
        case .claude: return "Claude"
        case .calendar: return "Calendar"
        case .weather: return "Weather"
        case .flow: return "Flow"
        case .shelf: return "Drop Zones"
        case .about: return "About"
        case .permissions: return "Permissions"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .display: return "sun.max.fill"
        case .battery: return "battery.100percent"
        case .connectivity: return "airpodspro"
        case .focus: return "moon.fill"
        case .nowPlaying: return "waveform"
        case .claude: return "sparkle"
        case .calendar: return "calendar"
        case .weather: return "cloud.sun.fill"
        case .flow: return "timer"
        case .shelf: return "tray.and.arrow.down.fill"
        case .about: return "info"
        case .permissions: return "lock.shield.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general, .about: return .gray
        case .permissions: return .blue
        case .display: return .orange
        case .battery: return .green
        case .connectivity: return Color(red: 0.2, green: 0.6, blue: 1)
        case .focus: return .indigo
        case .nowPlaying: return .pink
        case .claude: return ClaudeMonitor.tint
        case .calendar: return .red
        case .weather: return .cyan
        case .flow: return .orange
        case .shelf: return .teal
        }
    }

    static let sections: [(String?, [SettingsPane])] = [
        (nil, [.general]),
        ("Notifications", [.display, .battery, .connectivity, .focus]),
        ("Live Activities", [.nowPlaying, .claude, .calendar, .weather]),
        ("Productivity", [.flow, .shelf]),
        ("Islet", [.permissions, .about]),
    ]
}

struct SettingsView: View {
    let services: Services
    @State private var pane: SettingsPane? = .general

    var body: some View {
        NavigationSplitView {
            List(selection: $pane) {
                ForEach(SettingsPane.sections, id: \.1.first!.id) { title, panes in
                    Section {
                        ForEach(panes) { p in
                            Label {
                                Text(p.title)
                            } icon: {
                                Image(systemName: p.symbol)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 22, height: 22)
                                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(p.tint.gradient))
                            }
                            .tag(p)
                        }
                    } header: {
                        if let title { Text(title) }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 215, max: 260)
        } detail: {
            Group {
                switch pane ?? .general {
                case .general: GeneralPane()
                case .display: DisplayPane()
                case .battery: BatteryPane()
                case .connectivity:
                    ToggleOnlyPane(
                        key: Prefs.bluetoothNotify, label: "Show Bluetooth connections and battery",
                        footer: "AirPods: earbud and case levels when available.")
                case .focus: FocusPane()
                case .nowPlaying: NowPlayingPane()
                case .claude: ClaudePane(claude: services.claude)
                case .calendar: CalendarPane(calendar: services.calendar)
                case .weather: WeatherPane(weather: services.weather)
                case .flow: FlowPane()
                case .shelf: ShelfPane(shelf: services.shelf)
                case .permissions: PermissionsPane(services: services)
                case .about: AboutPane()
                }
            }
            .formStyle(.grouped)
            .navigationTitle((pane ?? .general).title)
        }
    }
}

// MARK: - Panes

private struct GeneralPane: View {
    @AppStorage(Prefs.showMenuBarIcon) private var menuBar = true
    @AppStorage(Prefs.showInFullScreen) private var fullScreen = false
    @AppStorage(Prefs.showInScreenshots) private var screenshots = true
    @AppStorage(Prefs.haptics) private var haptics = true
    @AppStorage(Prefs.emptyClickOpensDashboard) private var clickOpens = true
    @AppStorage(Prefs.unlockAnimation) private var unlock = true
    @AppStorage(Prefs.islandStyle) private var style = "auto"
    @AppStorage(Prefs.menuBarVeil) private var veil = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { launchAtLogin }, set: setLogin)) { Label("Open at login", systemImage: "power") }
                Toggle(isOn: $menuBar) { Label("Show in menu bar", systemImage: "menubar.rectangle") }
                Toggle(isOn: $fullScreen) { Label("Show in full screen", systemImage: "arrow.up.left.and.arrow.down.right") }
                Toggle(isOn: $screenshots) { Label("Visible in screenshots", systemImage: "camera.viewfinder") }
            } footer: {
                if let loginError { Text(loginError).foregroundStyle(.red) }
            }
            Section {
                TileRow(selection: $style, options: [("auto", "Automatic"), ("notch", "Notch"), ("island", "Island")]) { key in
                    StylePreview(style: key)
                }
                Toggle("Blend menu bar text under the island", isOn: $veil)
                    .disabled(style == "island")
            } header: {
                Text("Style")
            } footer: {
                Text(
                    "Notch: the island grows out of the notch, against the top of the screen. Island: a floating pill under the menu bar, like on iPhone. Automatic: notch on Macs that have one, island everywhere else."
                )
            }
            Section("Behavior") {
                Picker("Click on an empty island", selection: $clickOpens) {
                    Text("Open the dashboard").tag(true)
                    Text("Bounce only").tag(false)
                }
                Toggle("Trackpad haptic feedback", isOn: $haptics)
                Toggle("Unlock animation", isOn: $unlock)
            }
            Section("Gestures") {
                LabeledContent("Hover", value: "Bounces when nothing is running")
                LabeledContent("Two-finger swipe ← →", value: "Switch activity or page")
                LabeledContent("Swipe down / up", value: "Open / close")
                LabeledContent("Drag a file to the notch", value: "Shelf and AirDrop")
            }
            Section {
                HStack {
                    Button("Quit Islet") { NSApp.terminate(nil) }
                    Spacer()
                    // For when Islet stops responding to the normal quit.
                    Button("Force Quit", role: .destructive) { exit(0) }
                }
            }
        }
    }

    private func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Couldn’t change Open at login: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

private struct DisplayPane: View {
    @AppStorage(Prefs.hudEnabled) private var enabled = true
    @AppStorage(Prefs.hudReplaceSystem) private var replace = true
    @AppStorage(Prefs.hudDuration) private var duration = 1.5
    @AppStorage(Prefs.hudStyle) private var style = "glow"
    @AppStorage(Prefs.hudSpeed) private var speed = "smooth"
    @AppStorage(Prefs.hudShowPercent) private var percent = false
    @AppStorage(Prefs.hudScaleSymbol) private var scale = true
    @State private var trusted = AXIsProcessTrusted()
    private let poll = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                Toggle("Volume and brightness HUD", isOn: $enabled)
                Toggle("Replace the macOS HUD", isOn: $replace).disabled(!enabled)
                if enabled, replace, !trusted {
                    HStack {
                        Label("Needs Accessibility access to take over the keys.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Allow…") { HUDController.requestAccessibility() }
                    }
                }
            } footer: {
                Text(
                    "Without Accessibility access, Islet shows its HUD next to the macOS one (volume only). Switching audio devices and auto-brightness never trigger the HUD."
                )
            }
            Section("Appearance") {
                LabeledContent("Duration") {
                    HStack {
                        Slider(value: $duration, in: 0.8...3, step: 0.1).frame(width: 200)
                        Text(String(format: "%.1f s", duration)).monospacedDigit().frame(width: 44)
                    }
                }
                TileRow(selection: $style, options: [("white", "White"), ("accent", "Accent"), ("glow", "Glow")]) { key in
                    HUDBar(value: 0.66, style: key, speed: "instant").frame(width: 62)
                        .frame(width: 92, height: 30).background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.black))
                }
                TileRow(selection: $speed, options: [("smooth", "Smooth"), ("fast", "Fast"), ("instant", "Instant")]) { key in
                    Image(systemName: key == "smooth" ? "tortoise.fill" : key == "fast" ? "hare.fill" : "bolt.fill")
                        .font(.system(size: 15)).frame(width: 92, height: 30)
                }
                Toggle("Show percentage", isOn: $percent)
                Toggle("Scale the symbol with the level", isOn: $scale)
            }
        }
        .onReceive(poll) { _ in trusted = AXIsProcessTrusted() }
    }
}

/// Visual picker tiles, like System Settings' appearance choices.
/// Miniature of a style: a strip of screen with the island on it.
private struct StylePreview: View {
    let style: String

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.42, green: 0.55, blue: 0.95), Color(red: 0.75, green: 0.45, blue: 0.85)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
            Rectangle().fill(.white.opacity(0.25)).frame(height: 7)
            if style == "island" {
                Capsule().fill(.black).frame(width: 40, height: 10).padding(.top, 10)
            } else if style == "notch" {
                NotchShape(topRadius: 3, bottomRadius: 5).fill(.black).frame(width: 46, height: 11)
            } else {
                HStack(spacing: 6) {
                    NotchShape(topRadius: 2, bottomRadius: 4).fill(.black).frame(width: 28, height: 9)
                    Capsule().fill(.black).frame(width: 26, height: 8).padding(.top, 9)
                }
            }
        }
        .frame(width: 92, height: 38)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private struct TileRow<Preview: View>: View {
    @Binding var selection: String
    let options: [(String, String)]
    @ViewBuilder var preview: (String) -> Preview

    var body: some View {
        HStack(spacing: 14) {
            ForEach(options, id: \.0) { key, label in
                Button {
                    withAnimation(Motion.press) { selection = key }
                } label: {
                    VStack(spacing: 6) {
                        preview(key)
                            .padding(4)
                            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.quaternary))
                            .overlay(
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .strokeBorder(selection == key ? Color.accentColor : .clear, lineWidth: 2.5))
                        Text(label).font(.callout.weight(selection == key ? .semibold : .regular))
                            .foregroundStyle(selection == key ? .primary : .secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }
}

private struct BatteryPane: View {
    @AppStorage(Prefs.batteryNotify) private var notify = true
    @AppStorage(Prefs.batteryLowThreshold) private var threshold = 20
    @AppStorage(Prefs.batteryLowPower) private var lowPower = true
    @AppStorage(Prefs.batteryInHeader) private var header = true

    var body: some View {
        Form {
            Section {
                Toggle("Battery notifications", isOn: $notify)
                Stepper("Low battery alert: \(threshold)%", value: $threshold, in: 5...50, step: 5).disabled(!notify)
                Toggle("Low Power Mode", isOn: $lowPower).disabled(!notify)
            } footer: {
                Text("Charger connected, battery below the threshold (and below 10%), Low Power Mode turned on.")
            }
            Section { Toggle("Always show the battery in the dashboard", isOn: $header) }
        }
    }
}

private struct ToggleOnlyPane: View {
    let key: String
    let label: String
    let footer: String
    @AppStorage private var on: Bool

    init(key: String, label: String, footer: String) {
        self.key = key
        self.label = label
        self.footer = footer
        _on = AppStorage(wrappedValue: true, key)
    }

    var body: some View {
        Form {
            Section {
                Toggle(label, isOn: $on)
            } footer: {
                Text(footer)
            }
        }
    }
}

private struct FocusPane: View {
    @AppStorage(Prefs.focusNotify) private var on = true
    @State private var access = FocusMonitor.hasAccess

    var body: some View {
        Form {
            Section {
                Toggle("Show Focus mode changes", isOn: $on)
                if !access {
                    HStack {
                        Label("macOS protects Focus status: give Islet Full Disk Access.", systemImage: "lock.fill")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open…") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                        }
                    }
                }
            } footer: {
                Text("The mode’s symbol and color (Work, Personal, Sleep or custom), with On or Off.")
            }
        }
        .onAppear { access = FocusMonitor.hasAccess }
    }
}

private struct NowPlayingPane: View {
    @AppStorage(Prefs.nowPlayingEnabled) private var enabled = true
    @AppStorage(Prefs.sourceMusic) private var music = true
    @AppStorage(Prefs.sourceSpotify) private var spotify = true
    @AppStorage(Prefs.sourceWeb) private var web = true
    @AppStorage(Prefs.visualizer) private var visualizer = true
    @AppStorage(Prefs.artworkTint) private var tint = true

    var body: some View {
        Form {
            Section { Toggle("Now Playing activity", isOn: $enabled) }
            Section("Sources") {
                Toggle("Music", isOn: $music)
                Toggle("Spotify", isOn: $spotify)
                Toggle("YouTube and browsers", isOn: $web)
            }
            .disabled(!enabled)
            Section("Appearance") {
                Toggle("Audio visualizer", isOn: $visualizer)
                Toggle("Tint with the artwork color", isOn: $tint)
            }
            .disabled(!enabled)
        }
    }
}

private struct ClaudePane: View {
    @ObservedObject var claude: ClaudeMonitor
    @AppStorage(Prefs.claudeEnabled) private var enabled = true
    @AppStorage(Prefs.claudeOnlyWhenAway) private var away = true
    @AppStorage(Prefs.claudeSound) private var sound = true
    @AppStorage(Prefs.claudeUsage) private var usage = true
    @AppStorage(Prefs.claudeUsageAlerts) private var alerts = true
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                Toggle("Claude integration", isOn: $enabled)
                LabeledContent("Claude Code hooks") {
                    if claude.hooksInstalled {
                        HStack {
                            Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            Button("Remove") { run(claude.removeHooks) }
                        }
                    } else {
                        Button("Install") { run(claude.installHooks) }.buttonStyle(.borderedProminent)
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(
                        "Adds hooks to ~/.claude/settings.json so Claude Code tells Islet what it is doing, plus a status line that reports your usage limits. Your other settings are kept, and a backup is saved as settings.json.islet-backup. Works with Claude Code in the terminal and in the Claude app’s Code tab."
                    )
                    if let error { Text(error).foregroundStyle(.red) }
                }
            }
            Section("Notifications") {
                Toggle("Only when Claude is not in front", isOn: $away)
                Toggle("Subtle sound", isOn: $sound)
            }
            .disabled(!enabled)
            Section {
                Toggle("Show my usage limits", isOn: $usage)
                Toggle("Alert at 80% and 95%", isOn: $alerts).disabled(!usage)
                if usage {
                    LabeledContent("Status") {
                        HStack {
                            Text(status).foregroundStyle(.secondary)
                            if claude.usageStatus == .denied || claude.usageStatus == .expired {
                                Button("Retry") { claude.retryUsage() }
                            }
                        }
                    }
                }
            } header: {
                Text("Limits")
            } footer: {
                Text(
                    "Limits come from Claude Code’s status line. As a fallback, Islet reads Claude Code’s sign-in token from your keychain (macOS asks first) to fetch your usage at most every 15 minutes. Nothing else is sent anywhere."
                )
            }
            .disabled(!enabled)
        }
    }

    private var status: String {
        switch claude.usageStatus {
        case .ok: return "Connected"
        case .loading, .idle: return "Loading…"
        case .noCredentials: return "No Claude Code account found"
        case .denied: return "Keychain access denied"
        case .expired: return "Token expired — open Claude Code"
        case .failed(let why): return why
        }
    }

    private func run(_ action: () throws -> Void) {
        do { try action(); error = nil } catch { self.error = error.localizedDescription }
    }
}

private struct CalendarPane: View {
    @ObservedObject var calendar: CalendarService
    @AppStorage(Prefs.calendarEnabled) private var enabled = true
    @AppStorage(Prefs.calendarLead) private var lead = 5

    var body: some View {
        Form {
            Section {
                Toggle("Calendar", isOn: $enabled)
                Picker("Remind me before an event", selection: $lead) {
                    ForEach([1, 5, 10, 15, 30], id: \.self) { Text("\($0) min").tag($0) }
                }
                .disabled(!enabled)
                LabeledContent("Access") {
                    switch calendar.access {
                    case .granted: Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .denied: Text("Denied — see System Settings › Privacy").foregroundStyle(.secondary)
                    case .unknown: Button("Allow…") { calendar.requestAccess() }
                    }
                }
            }
        }
        .onChange(of: lead) { calendar.reload() }
        .onChange(of: enabled) { calendar.reload() }
    }
}

private struct WeatherPane: View {
    @ObservedObject var weather: WeatherService
    @AppStorage(Prefs.weatherEnabled) private var enabled = true
    @AppStorage(Prefs.weatherCity) private var city = ""
    @AppStorage(Prefs.weatherFahrenheit) private var fahrenheit = false

    var body: some View {
        Form {
            Section {
                Toggle("Weather", isOn: $enabled)
                TextField("City", text: $city, prompt: Text("Current location"))
                Picker("Unit", selection: $fahrenheit) {
                    Text("°C").tag(false)
                    Text("°F").tag(true)
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("Forecasts from Open-Meteo, refreshed at most every 30 minutes and only when the Weather page is open.")
            }
            .disabled(!enabled)
        }
    }
}

private struct FlowPane: View {
    @AppStorage(Prefs.flowEnabled) private var enabled = true
    @AppStorage(Prefs.flowFocus) private var focus = 25
    @AppStorage(Prefs.flowShort) private var short = 5
    @AppStorage(Prefs.flowLong) private var long = 15
    @AppStorage(Prefs.flowRounds) private var rounds = 4
    @AppStorage(Prefs.flowAutoContinue) private var auto = true
    @AppStorage(Prefs.flowSound) private var sound = true
    @AppStorage(Prefs.flowTone) private var tone = "Radar"

    var body: some View {
        Form {
            Section { Toggle("Flow timer", isOn: $enabled) }
            Section("Durations") {
                Stepper("Focus: \(focus) min", value: $focus, in: 5...120, step: 5)
                Stepper("Short break: \(short) min", value: $short, in: 1...30)
                Stepper("Long break: \(long) min", value: $long, in: 5...60, step: 5)
                Stepper("Long break every \(rounds) sessions", value: $rounds, in: 2...8)
            }
            Section {
                Toggle("Continue automatically", isOn: $auto)
                Toggle("Ring when a phase ends", isOn: $sound)
                HStack {
                    Picker("Ringtone", selection: $tone) {
                        ForEach(TimerAlarm.tones, id: \.self) { Text($0).tag($0) }
                    }
                    Button {
                        TimerAlarm.shared.preview(tone)
                    } label: {
                        Image(systemName: "play.circle")
                    }
                    .buttonStyle(.borderless)
                }
                .disabled(!sound)
            }
        }
    }
}

private struct ShelfPane: View {
    @ObservedObject var shelf: ShelfStore
    @AppStorage(Prefs.shelfEnabled) private var enabled = true

    var body: some View {
        Form {
            Section {
                Toggle("Drop zones around the notch", isOn: $enabled)
                LabeledContent("Files on the Shelf", value: "\(shelf.items.count)")
                Button("Clear the Shelf") { shelf.clear() }.disabled(shelf.items.isEmpty)
            } footer: {
                Text(
                    "Drag a file to the notch: drop it on the Shelf to keep it at hand, or on AirDrop to share it. Files stay where they are."
                )
            }
        }
    }
}

private struct AboutPane: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("Islet").font(.largeTitle.weight(.semibold))
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                .foregroundStyle(.secondary)
            Text("The Dynamic Island, made for the Mac’s notch.\nNo data collected.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Every macOS permission Islet uses, its live state, and a way to grant it. Each button
/// first resets that one permission for Islet (`tccutil reset`), then asks again as on a
/// first launch: after an update, macOS often keeps a stale entry that looks granted but
/// no longer matches the app, and only a fresh request fixes it.
private struct PermissionsPane: View {
    let services: Services
    @State private var tick = 0
    private let poll = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private struct Item: Identifiable {
        let id: String
        let symbol: String
        let detail: String
        let granted: Bool?
        /// `tccutil` service name; nil when macOS has none to reset (Location).
        let service: String?
        let request: () -> Void
    }

    private var items: [Item] {
        _ = tick
        let pane = { (anchor: String) -> Void in
            _ = NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
        }
        let location = CLLocationManager().authorizationStatus
        return [
            Item(
                id: "Accessibility", symbol: "accessibility", detail: "Replace the volume and brightness HUD, keep the call window drawable",
                granted: AXIsProcessTrusted(), service: "Accessibility",
                request: {
                    services.hud.syncTap()  // fall back to listening until the new grant lands
                    HUDController.requestAccessibility()
                }),
            Item(
                id: "Screen Recording", symbol: "rectangle.dashed.badge.record", detail: "Call video in the island",
                granted: CGPreflightScreenCaptureAccess(), service: "ScreenCapture", request: { _ = CGRequestScreenCaptureAccess() }),
            Item(
                id: "Calendar", symbol: "calendar", detail: "Upcoming events and reminders",
                granted: EKEventStore.authorizationStatus(for: .event) == .fullAccess, service: "Calendar",
                request: { services.calendar.requestAccess() }),
            Item(
                id: "Location", symbol: "location.fill", detail: "Local weather (or set a city in Weather)",
                granted: location == .authorizedAlways, service: nil, request: { services.weather.refreshIfStale() }),
            Item(
                id: "Bluetooth", symbol: "airpodspro", detail: "AirPods connection and battery",
                granted: CBCentralManager.authorization == .allowedAlways, service: "BluetoothAlways",
                request: { services.bluetooth.start() }),
            Item(
                id: "Full Disk Access", symbol: "internaldrive.fill", detail: "Focus modes",
                granted: FocusMonitor.hasAccess, service: "SystemPolicyAllFiles", request: { pane("Privacy_AllFiles") }),
            Item(
                id: "Automation", symbol: "music.note", detail: "Music and Spotify (asked again at the next song)",
                granted: nil, service: "AppleEvents", request: { pane("Privacy_Automation") }),
        ]
    }

    var body: some View {
        Form {
            Section {
                ForEach(items) { item in
                    HStack(spacing: 12) {
                        Image(systemName: item.symbol).frame(width: 22).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.id)
                            Text(item.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if item.granted == true {
                            Label("Allowed", systemImage: "checkmark.circle.fill").labelStyle(.iconOnly).foregroundStyle(.green)
                        } else {
                            Button(item.granted == nil ? "Reset…" : "Allow…") { freshRequest(item) }
                        }
                    }
                    .contextMenu {
                        Button("Reset and ask again") { freshRequest(item) }
                    }
                }
            } footer: {
                Text(
                    "Each button first resets that permission for Islet, then asks for it again as on a first launch. Right-click a granted row to redo it. macOS asks for each permission separately; some (Screen Recording) only apply after Islet relaunches."
                )
            }
        }
        .onReceive(poll) { _ in tick += 1 }
    }

    /// Reset this permission for Islet, then ask again as on a first launch.
    private func freshRequest(_ item: Item) {
        if let service = item.service {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            p.arguments = ["reset", service, Bundle.main.bundleIdentifier ?? "app.islet.Islet"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
        }
        // Give the privacy database a beat to drop the old entry before asking.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            item.request()
            tick += 1
        }
    }
}
