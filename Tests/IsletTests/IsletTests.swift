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

struct AgentParsingTests {
    private func line(_ type: String, _ payload: [String: Any], at date: Date = Date()) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let obj: [String: Any] = ["timestamp": iso.string(from: date), "type": type, "payload": payload]
        return String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
    }

    @Test func codexWorkingWithTool() {
        let text = [
            line("session_meta", ["cwd": "/Users/me/Code/Islet"]),
            line("event_msg", ["type": "task_started"]),
            line("response_item", ["type": "function_call", "name": "exec_command", "arguments": #"{"cmd":"swift build"}"#]),
        ].joined(separator: "\n")
        let s = CodexMonitor.parse(text, modified: Date(), previous: nil)
        #expect(s.working)
        #expect(s.project == "Islet")
        #expect(s.activity == "Terminal · swift build")
    }

    @Test func codexDoneAfterTaskComplete() {
        let text = [
            line("event_msg", ["type": "task_started"], at: Date().addingTimeInterval(-60)),
            line("event_msg", ["type": "task_complete"]),
        ].joined(separator: "\n")
        let s = CodexMonitor.parse(text, modified: Date(), previous: nil)
        #expect(!s.working)
        #expect(s.finished != nil)
        #expect(s.activity == nil)
    }

    @Test func codexLimitsSkipWindowsThatReset() {
        let future = Date().addingTimeInterval(3600).timeIntervalSince1970
        let limits: [String: Any] = [
            "primary": ["used_percent": 42.0, "window_minutes": 300, "resets_at": future],
            "secondary": ["used_percent": 90.0, "window_minutes": 10080, "resets_at": 1_000_000],
        ]
        let parsed = CodexMonitor.parseLimits(limits)
        #expect(parsed.count == 1)
        #expect(parsed.first?.label == "Session")
        #expect(parsed.first?.utilization == 42)
    }

    @Test func antigravityWorkingWhileAToolRuns() {
        let text = [
            #"{"step_index":1,"type":"USER_INPUT","status":"DONE","created_at":"2026-10-26T14:57:26Z"}"#,
            #"{"step_index":2,"type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-10-26T14:57:28Z","tool_calls":[{"name":"run_command","args":{"CommandLine":"\"swift build\"","toolSummary":"\"Build the app\""}}]}"#,
            #"{"step_index":3,"type":"RUN_COMMAND","status":"RUNNING","created_at":"2026-10-26T14:57:29Z"}"#,
            #"{"step_index":4,"type":"EPHEMERAL_MESSAGE","status":"DONE","created_at":"2026-10-26T14:57:30Z"}"#,
        ].joined(separator: "\n")
        let s = GeminiMonitor.parseTranscript(text, title: "Islet", modified: Date())
        #expect(s.working)
        #expect(s.activity == "Build the app")
        #expect(s.project == "Islet")
        #expect(s.started != nil)
    }

    @Test func antigravityDoneAfterFinalAnswer() {
        let text = [
            #"{"step_index":1,"type":"USER_INPUT","status":"DONE","created_at":"2026-10-26T14:57:26Z"}"#,
            #"{"step_index":2,"type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-10-26T14:57:28Z","content":"Hi!"}"#,
        ].joined(separator: "\n")
        let s = GeminiMonitor.parseTranscript(text, title: nil, modified: Date())
        #expect(!s.working)
        #expect(s.finished != nil)
        #expect(GeminiMonitor.annotationTitle(#"title:"Sharing A Built App Easily" last_user_view_time:{seconds:1}"#) == "Sharing A Built App Easily")
    }

    @Test func geminiThinkingUntilItAnswers() throws {
        let asked = try JSONSerialization.data(withJSONObject: ["messages": [["type": "user", "content": "hi"]]])
        #expect(GeminiMonitor.parseChat(asked, project: "x", modified: Date())?.working == true)
        let answered = try JSONSerialization.data(withJSONObject: [
            "messages": [["type": "user", "content": "hi"], ["type": "gemini", "content": "hello"]],
        ])
        #expect(GeminiMonitor.parseChat(answered, project: "x", modified: Date())?.working == false)
    }
}

@Suite(.serialized) struct PageOrderTests {
    @Test func savedOrderAndHiddenPagesApply() {
        let d = UserDefaults.standard
        Prefs.register()
        defer { d.removeObject(forKey: Prefs.pageOrder); d.removeObject(forKey: Prefs.hiddenPages) }
        d.set("weather,calendar", forKey: Prefs.pageOrder)
        d.set("shelf", forKey: Prefs.hiddenPages)
        let pages = Page.enabled
        #expect(Array(pages.prefix(2)) == [.weather, .calendar])
        #expect(!pages.contains(.shelf))
        // The page of an open live activity stays reachable even when hidden.
        #expect(Page.enabled(including: .shelf).contains(.shelf))
    }
}

struct AILineupTests {
    let gemini = AgentState(name: "Gemini", finished: Date().addingTimeInterval(-30))
    let oldCodex = AgentState(name: "Codex", finished: Date().addingTimeInterval(-3 * 86400))

    @Test func onlyGeminiInUseTakesClaudesPlace() {
        let l = AILineup.make(claudeOn: true, claudeWorking: false, claudeLastActive: nil, agents: [gemini, oldCodex])
        #expect(!l.claudeLeads)
        #expect(l.others.map(\.name) == ["Gemini"])
    }

    @Test func claudeInUseLeadsWithGeminiBelow() {
        let l = AILineup.make(claudeOn: true, claudeWorking: false, claudeLastActive: Date().addingTimeInterval(-60), agents: [gemini])
        #expect(l.claudeLeads)
        #expect(l.others.map(\.name) == ["Gemini"])
    }

    @Test func nothingInUseShowsClaudeAlone() {
        let l = AILineup.make(claudeOn: true, claudeWorking: false, claudeLastActive: nil, agents: [oldCodex])
        #expect(l.claudeLeads)
        #expect(l.others.isEmpty)
    }

    @Test func finishedOverAMinuteAgoLeavesOnlyClaude() {
        let done = AgentState(name: "Antigravity", finished: Date().addingTimeInterval(-90))
        let l = AILineup.make(claudeOn: true, claudeWorking: false, claudeLastActive: nil, agents: [done])
        #expect(l.claudeLeads)
        #expect(l.others.isEmpty)
    }
}
