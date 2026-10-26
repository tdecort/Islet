import Foundation
import Testing
@testable import Islet

@Suite struct ClaudeHooksTests {
    private func tempSettings(_ json: String?) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("settings.json")
        if let json { try Data(json.utf8).write(to: url) }
        return url
    }

    private func read(_ url: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }

    @Test func installKeepsExistingSettingsAndHooks() throws {
        let url = try tempSettings(
            #"""
            {"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}
            """#)
        try ClaudeHooks.install(at: url, command: "/x/Islet --claude-event")
        let s = try read(url)
        #expect(s["model"] as? String == "opus")
        let stop = (s["hooks"] as! [String: Any])["Stop"] as! [[String: Any]]
        let commands = stop.flatMap { ($0["hooks"] as! [[String: Any]]).map { $0["command"] as! String } }
        #expect(commands == ["say done", "/x/Islet --claude-event"])
        #expect(ClaudeHooks.isInstalled(at: url))
        #expect(FileManager.default.fileExists(atPath: url.appendingPathExtension("islet-backup").path))
    }

    @Test func installTwiceDoesNotDuplicate() throws {
        let url = try tempSettings(nil)
        try ClaudeHooks.install(at: url, command: "/a --claude-event")
        try ClaudeHooks.install(at: url, command: "/b --claude-event")
        let hooks = try read(url)["hooks"] as! [String: Any]
        for event in ClaudeHooks.events {
            let groups = hooks[event] as! [[String: Any]]
            #expect(groups.count == 1)
            #expect((groups[0]["hooks"] as! [[String: Any]])[0]["command"] as? String == "/b --claude-event")
        }
    }

    @Test func uninstallRemovesOnlyIsletEntries() throws {
        let url = try tempSettings(
            #"""
            {"env":{"A":"1"},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}
            """#)
        try ClaudeHooks.install(at: url, command: "/x --claude-event")
        try ClaudeHooks.uninstall(at: url)
        let s = try read(url)
        #expect((s["env"] as? [String: String]) == ["A": "1"])
        let hooks = s["hooks"] as! [String: Any]
        #expect(Set(hooks.keys) == ["Stop"])
        #expect(!ClaudeHooks.isInstalled(at: url))
    }

    @Test func uninstallOnCleanFileLeavesNoHooksKey() throws {
        let url = try tempSettings(#"{"model":"opus"}"#)
        try ClaudeHooks.install(at: url, command: "/x --claude-event")
        try ClaudeHooks.uninstall(at: url)
        let s = try read(url)
        #expect(s["hooks"] == nil)
        #expect(s["model"] as? String == "opus")
    }
}

@Suite struct ClaudeStatusLineTests {
    private func tempSettings(_ json: String?) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("settings.json")
        if let json { try Data(json.utf8).write(to: url) }
        return url
    }

    private func read(_ url: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }

    @Test func installAddsStatusLineWhenNone() throws {
        let url = try tempSettings(#"{"model":"opus"}"#)
        try ClaudeHooks.install(at: url, command: "/x --claude-event", statusCommand: "/x --claude-status")
        let status = try read(url)["statusLine"] as? [String: Any]
        #expect(status?["command"] as? String == "/x --claude-status")
        #expect(status?["type"] as? String == "command")
    }

    @Test func installNeverReplacesUsersStatusLine() throws {
        let url = try tempSettings(#"{"statusLine":{"type":"command","command":"~/my-line.sh"}}"#)
        try ClaudeHooks.install(at: url, command: "/x --claude-event", statusCommand: "/x --claude-status")
        let status = try read(url)["statusLine"] as? [String: Any]
        #expect(status?["command"] as? String == "~/my-line.sh")
        try ClaudeHooks.uninstall(at: url)
        #expect((try read(url)["statusLine"] as? [String: Any])?["command"] as? String == "~/my-line.sh")
    }

    @Test func uninstallRemovesOnlyIsletStatusLine() throws {
        let url = try tempSettings(#"{"model":"opus"}"#)
        try ClaudeHooks.install(at: url, command: "/x --claude-event", statusCommand: "/x --claude-status")
        try ClaudeHooks.uninstall(at: url)
        let s = try read(url)
        #expect(s["statusLine"] == nil)
        #expect(s["model"] as? String == "opus")
    }
}

@Suite struct GeometryTests {
    private func model() -> IslandModel {
        let m = IslandModel(services: Services())
        m.setScreen(notch: CGSize(width: 179, height: 32), detached: false)
        return m
    }

    @Test func idleHidesInsideHardwareNotch() {
        let g = model().target(for: .idle)
        #expect(g.width < 179 && g.height < 32 && g.top == 0)
    }

    @Test func bumpGrowsBeyondNotch() {
        let m = model()
        m.preview(hovering: true, bumped: true)
        let g = m.target(for: .idle)
        #expect(g.width > 179 && g.height > 32)
    }

    @Test func expandedIsTheLargestState() {
        let m = model()
        let expanded = m.target(for: .expanded(.nowPlaying))
        let hud = m.target(for: .transient(.hud(.volume, 0.5, muted: false)))
        #expect(expanded.width > hud.width && expanded.height > hud.height && expanded.shadow > 0)
    }

    @Test func hudValueChangeKeepsContentIdentity() {
        let a = IslandState.transient(.hud(.volume, 0.2, muted: false))
        let b = IslandState.transient(.hud(.volume, 0.8, muted: false))
        #expect(a.contentKey == b.contentKey)
    }
}

@Suite struct BubbleTests {
    @Test func bubbleNeverDuplicatesWhatIsShown() {
        Prefs.register()
        UserDefaults.standard.set(false, forKey: Prefs.claudeUsage)  // no network or keychain in tests
        let services = Services()
        let model = IslandModel(services: services)
        model.setScreen(notch: CGSize(width: 179, height: 32), detached: false)
        services.nowPlaying.loadPreview(.init(title: "T", artist: "A", album: "", duration: 100), artwork: nil, playing: true, elapsed: 0)
        services.claude.loadPreview(working: true)
        model.refreshActivities()

        // Music on screen: Claude in the bubble.
        #expect(model.state == .compact(.nowPlaying))
        #expect(model.secondaryActivity == .claude)

        // Swipe to Claude: music moves into the bubble.
        model.swipe(.left)
        #expect(model.state == .glance(.claude))
        #expect(model.secondaryActivity == .nowPlaying)

        // Tap the bubble: music comes back, Claude returns to the bubble.
        model.clickSecondary()
        #expect(model.state == .compact(.nowPlaying))
        #expect(model.secondaryActivity == .claude)
        UserDefaults.standard.removeObject(forKey: Prefs.claudeUsage)
    }
}

@Suite struct ClaudePaceTests {
    @Test func aheadOfPaceSaysSlowDown() {
        // 70 % used with 4 h of a 5 h window still left.
        let w = ClaudeMonitor.Window(utilization: 70, resetsAt: Date().addingTimeInterval(4 * 3600), length: 5 * 3600)
        #expect(w.pace == .slowDown)
    }

    @Test func onPaceIsGood() {
        let w = ClaudeMonitor.Window(utilization: 45, resetsAt: Date().addingTimeInterval(55 * 60), length: 5 * 3600)
        #expect(w.pace == .good)
    }

    @Test func nearLimit() {
        let w = ClaudeMonitor.Window(utilization: 93, resetsAt: Date().addingTimeInterval(60), length: 5 * 3600)
        #expect(w.pace == .limit)
    }
}
