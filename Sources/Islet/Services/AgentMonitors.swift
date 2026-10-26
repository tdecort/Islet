import AppKit
import Combine
import CoreServices
import SwiftUI

/// One coding assistant other than Claude, as the island shows it.
struct AgentState: Equatable {
    struct Limit: Equatable {
        var label: String
        var utilization: Double  // 0...100
        var resetsAt: Date?
    }

    var name: String
    var project: String?
    var working = false
    var activity: String?
    var started: Date?
    var finished: Date?
    var limits: [Limit] = []
}

/// Which assistants the AI page shows, and which one leads it. Codex and Gemini show while
/// they work and for a minute after; then only the main assistant stays. Claude leads
/// whenever it was used in the last 12 hours, or when no other assistant is showing;
/// otherwise the one at work takes its place.
struct AILineup: Equatable {
    var claudeLeads: Bool
    /// Shown under Claude, or, when Claude doesn't lead, the first one leads.
    var others: [AgentState]

    static let claudeInUseFor: TimeInterval = 12 * 3600
    static let othersLingerFor: TimeInterval = 60

    static func make(
        claudeOn: Bool, claudeWorking: Bool, claudeLastActive: Date?, agents: [AgentState], now: Date = Date()
    ) -> AILineup {
        func within(_ span: TimeInterval, _ date: Date?) -> Bool { date.map { now.timeIntervalSince($0) < span } ?? false }
        let used = agents.filter { $0.working || within(othersLingerFor, $0.finished) }
            .sorted { $0.working && !$1.working }
        let claudeUsed = claudeOn && (claudeWorking || within(claudeInUseFor, claudeLastActive))
        return AILineup(claudeLeads: claudeOn && (claudeUsed || used.isEmpty), others: used)
    }
}

/// Nothing is written when the minute after a finished run runs out, so ask the island to
/// lay itself out again then, dropping the assistant from the AI page.
func redrawWhenLingerEnds<M: ObservableObject>(_ state: AgentState, _ monitor: M) where M.ObjectWillChangePublisher == ObservableObjectPublisher {
    guard !state.working, let finished = state.finished else { return }
    let left = AILineup.othersLingerFor - Date().timeIntervalSince(finished)
    guard left > 0 else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + left + 0.5) { [weak monitor] in monitor?.objectWillChange.send() }
}

/// Calls back when anything changes under the watched folders (FSEvents, recursive).
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void

    init?(paths: [String], latency: TimeInterval = 0.4, onChange: @escaping () -> Void) {
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return nil }
        self.onChange = onChange
        var context = FSEventStreamContext(
            version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        context.info = Unmanaged.passUnretained(self).toOpaque()
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        guard
            let s = FSEventStreamCreate(
                nil, callback, &context, existing as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
                FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer))
        else { return nil }
        stream = s
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}

/// Reads the last `bytes` of a file, so long logs are never loaded whole.
func readTail(of url: URL, bytes: Int) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    let size = (try? handle.seekToEnd()) ?? 0
    try? handle.seek(toOffset: size > UInt64(bytes) ? size - UInt64(bytes) : 0)
    return handle.readDataToEndOfFile().flatMap { String(data: $0, encoding: .utf8) }
}

private extension FileHandle {
    func readDataToEndOfFile() -> Data? { try? readToEnd() }
}

// MARK: - Codex

/// OpenAI Codex (CLI and app), read from the session logs it writes in ~/.codex/sessions:
/// task start and end, the tool it is running, the project, and its rate limits.
/// Nothing leaves the Mac.
final class CodexMonitor: ObservableObject {
    @Published private(set) var state: AgentState?
    var onDone: ((String, String) -> Void)?

    private var watcher: FolderWatcher?
    private let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
    private var lastFile: URL?

    var isWorking: Bool { state?.working == true }

    func loadPreview(_ state: AgentState) { self.state = state }

    func sync() {
        if Prefs.bool(Prefs.aiCodex) {
            guard watcher == nil else { return }
            watcher = FolderWatcher(paths: [root.path]) { [weak self] in self?.refresh() }
            refresh()
        } else {
            watcher = nil
            if state != nil { state = nil }
        }
    }

    private func refresh() {
        guard let file = Self.latestSession(in: root), let text = readTail(of: file, bytes: 256 * 1024) else { return }
        lastFile = file
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        let next = Self.parse(text, modified: modified, previous: state)
        if let previous = state, previous.working, !next.working, let project = next.project ?? previous.project {
            onDone?("Codex", project)
        }
        if next != state {
            state = next
            redrawWhenLingerEnds(next, self)
        }
    }

    /// The most recently written rollout file. Sessions are filed by day (YYYY/MM/DD), so
    /// walking the newest folders first finds it without listing the whole history.
    static func latestSession(in root: URL) -> URL? {
        let fm = FileManager.default
        func newestFirst(_ dir: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
        }
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        for year in newestFirst(root) {
            for month in newestFirst(year) {
                for day in newestFirst(month) {
                    let files = newestFirst(day).filter { $0.pathExtension == "jsonl" }
                    if let latest = files.max(by: { modified($0) < modified($1) }) { return latest }
                }
            }
        }
        return nil
    }

    /// Turns the tail of a Codex session log into what the island shows.
    static func parse(_ text: String, modified: Date, previous: AgentState?) -> AgentState {
        var state = AgentState(name: "Codex")
        state.project = previous?.project
        var lastStart: Date?
        var lastEnd: Date?
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for line in text.split(separator: "\n") {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            let payload = obj["payload"] as? [String: Any] ?? [:]
            let stamp = (obj["timestamp"] as? String).flatMap(iso.date)
            switch (obj["type"] as? String, payload["type"] as? String) {
            case ("session_meta", _), ("turn_context", _):
                if let cwd = payload["cwd"] as? String { state.project = URL(fileURLWithPath: cwd).lastPathComponent }
            case ("event_msg", "task_started"):
                lastStart = stamp ?? lastStart
                state.activity = nil
            case ("event_msg", "task_complete"):
                lastEnd = stamp ?? lastEnd
                state.activity = nil
            case ("response_item", "function_call"), ("response_item", "custom_tool_call"):
                state.activity = toolLabel(payload["name"] as? String ?? "tool", arguments: payload["arguments"] as? String)
            case ("event_msg", "exec_command_end"), ("event_msg", "patch_apply_end"):
                state.activity = nil
            case ("event_msg", "token_count"):
                if let limits = payload["rate_limits"] as? [String: Any] { state.limits = parseLimits(limits) }
            default:
                break
            }
        }
        // Working when the last task started after the last one ended, and the log is
        // still being written (a crashed session goes quiet).
        let open = lastStart.map { start in lastEnd.map { $0 < start } ?? true } ?? false
        state.working = open && Date().timeIntervalSince(modified) < 30 * 60
        state.started = state.working ? lastStart : nil
        state.finished = state.working ? nil : lastEnd
        if !state.working { state.activity = nil }
        return state
    }

    private static func toolLabel(_ name: String, arguments: String?) -> String {
        let args = arguments.flatMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
        switch name {
        case "shell", "exec_command", "local_shell":
            let command = (args?["cmd"] as? String) ?? (args?["command"] as? [String])?.last ?? (args?["command"] as? String)
            return command.map { "Terminal · \(String($0.prefix(50)))" } ?? "Terminal"
        case "apply_patch": return "Editing"
        case "update_plan": return "Planning"
        case "web_search", "web.run": return "Web"
        default: return name.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    static func parseLimits(_ limits: [String: Any]) -> [AgentState.Limit] {
        ["primary", "secondary"].compactMap { key in
            guard let w = limits[key] as? [String: Any], let used = (w["used_percent"] as? NSNumber)?.doubleValue else { return nil }
            let minutes = (w["window_minutes"] as? NSNumber)?.doubleValue ?? 0
            let reset = (w["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            // A window that has already reset says nothing about today.
            if let reset, reset < Date() { return nil }
            let label = minutes >= 7 * 24 * 60 ? "Week" : minutes >= 24 * 60 ? "Day" : "Session"
            return AgentState.Limit(label: label, utilization: used, resetsAt: reset)
        }
    }
}

// MARK: - Gemini CLI and Antigravity

/// Google's assistants. Gemini CLI writes each chat as JSON under ~/.gemini/tmp, so the
/// last speaker says whether it is thinking or done. Antigravity logs every step of a
/// conversation (its type, status and tool) to a transcript under ~/.gemini/antigravity/brain.
/// Whichever was written to last is the one shown.
final class GeminiMonitor: ObservableObject {
    @Published private(set) var state: AgentState?
    var onDone: ((String, String) -> Void)?

    private var watcher: FolderWatcher?
    private let gemini = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini")

    var isWorking: Bool { state?.working == true }

    func loadPreview(_ state: AgentState) { self.state = state }

    func sync() {
        if Prefs.bool(Prefs.aiGemini) {
            guard watcher == nil else { return }
            let paths = [gemini.appendingPathComponent("tmp").path, gemini.appendingPathComponent("antigravity/brain").path]
            watcher = FolderWatcher(paths: paths, latency: 0.5) { [weak self] in self?.refresh() }
            refresh()
        } else {
            watcher = nil
            if state != nil { state = nil }
        }
    }

    private func refresh() {
        let antigravity = Self.latestAntigravity(in: gemini.appendingPathComponent("antigravity"))
        let cli = Self.latestChat(in: gemini.appendingPathComponent("tmp"))
        let candidates = [antigravity, cli].compactMap { $0 }
        guard let latest = candidates.max(by: { $0.modified < $1.modified }) else { return }
        update(latest.state)
    }

    private func update(_ next: AgentState) {
        if let previous = state, previous.working, !next.working, previous.name == next.name {
            onDone?(next.name, next.project ?? next.name)
        }
        if next != state {
            state = next
            redrawWhenLingerEnds(next, self)
        }
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    // MARK: Antigravity

    /// The Antigravity conversation whose transcript was written last, titled as in the app.
    static func latestAntigravity(in root: URL) -> (state: AgentState, modified: Date)? {
        let brain = root.appendingPathComponent("brain")
        let transcripts = ((try? FileManager.default.contentsOfDirectory(at: brain, includingPropertiesForKeys: nil)) ?? [])
            .map { $0.appendingPathComponent(".system_generated/logs/transcript.jsonl") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard let latest = transcripts.max(by: { modified($0) < modified($1) }),
            let text = readTail(of: latest, bytes: 128 * 1024)
        else { return nil }
        let id = latest.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        let title = (try? String(contentsOf: root.appendingPathComponent("annotations/\(id).pbtxt"), encoding: .utf8))
            .flatMap(annotationTitle)
        let date = modified(latest)
        return (parseTranscript(text, title: title, modified: date), date)
    }

    /// `title:"Sharing A Built App Easily" last_user_view_time:{…}` → the title.
    static func annotationTitle(_ text: String) -> String? {
        guard let start = text.range(of: "title:\"")?.upperBound,
            let end = text[start...].firstIndex(of: "\"")
        else { return nil }
        return String(text[start..<end])
    }

    /// Done once the model has answered without asking for a tool and nothing is running;
    /// working at any other point of a turn (a request sent, a tool requested or running).
    static func parseTranscript(_ text: String, title: String?, modified: Date) -> AgentState {
        let bookkeeping: Set<String> = ["EPHEMERAL_MESSAGE", "CHECKPOINT", "SYSTEM_MESSAGE", "CONVERSATION_HISTORY"]
        let iso = ISO8601DateFormatter()
        var steps: [[String: Any]] = []
        for line in text.split(separator: "\n") {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                let type = obj["type"] as? String, !bookkeeping.contains(type)
            else { continue }
            steps.append(obj)
        }
        var state = AgentState(name: "Antigravity", project: title)
        guard let last = steps.last else { return state }
        let finalAnswer = last["type"] as? String == "PLANNER_RESPONSE"
            && (last["tool_calls"] as? [Any])?.isEmpty != false
            && last["status"] as? String == "DONE"
        // A turn that went quiet for half an hour was interrupted, not still running.
        state.working = !finalAnswer && Date().timeIntervalSince(modified) < 30 * 60
        let lastPrompt = steps.last { $0["type"] as? String == "USER_INPUT" }
        state.started = state.working ? (lastPrompt?["created_at"] as? String).flatMap(iso.date) : nil
        state.finished = state.working ? nil : ((last["created_at"] as? String).flatMap(iso.date) ?? modified)
        if state.working {
            let call = steps.last { ($0["tool_calls"] as? [Any])?.isEmpty == false }
            if steps.last.map({ $0["type"] as? String }) != "USER_INPUT",
                let tool = (call?["tool_calls"] as? [[String: Any]])?.last
            {
                state.activity = toolLabel(tool)
            }
        }
        return state
    }

    private static func toolLabel(_ call: [String: Any]) -> String {
        let args = call["args"] as? [String: Any] ?? [:]
        // Arguments are JSON-encoded strings ("\"Clone repo\""): drop the quotes.
        func arg(_ key: String) -> String? {
            (args[key] as? String).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        if let summary = arg("toolSummary") { return summary }
        switch call["name"] as? String ?? "" {
        case "run_command": return arg("CommandLine").map { "Terminal · \(String($0.prefix(50)))" } ?? "Terminal"
        case "view_file", "list_dir", "find_by_name", "grep_search": return "Reading"
        case "write_to_file", "replace_file_content", "multi_replace_file_content": return "Editing"
        case "search_web", "read_url_content": return "Web"
        case let name: return name.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    // MARK: Gemini CLI

    /// The Gemini CLI chat written most recently, if it is less than 30 minutes old.
    static func latestChat(in tmp: URL) -> (state: AgentState, modified: Date)? {
        let fm = FileManager.default
        let chats = ((try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)) ?? [])
            .flatMap { (try? fm.contentsOfDirectory(at: $0.appendingPathComponent("chats"), includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] }
            .filter { $0.pathExtension == "json" }
        guard
            let latest = chats.max(by: {
                ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                    < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
            }),
            let modified = try? latest.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
            Date().timeIntervalSince(modified) < 30 * 60,
            let data = try? Data(contentsOf: latest)
        else { return nil }
        let project = (try? String(contentsOf: latest.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".project_root"), encoding: .utf8))
            .map { URL(fileURLWithPath: $0.trimmingCharacters(in: .whitespacesAndNewlines)).lastPathComponent }
        return parseChat(data, project: project, modified: modified).map { ($0, modified) }
    }

    /// Thinking while the last real message is the user's; done once Gemini has answered.
    static func parseChat(_ data: Data, project: String?, modified: Date) -> AgentState? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let messages = obj["messages"] as? [[String: Any]]
        else { return nil }
        let spoken = messages.filter { ["user", "gemini"].contains($0["type"] as? String) }
        guard let last = spoken.last else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = (last["timestamp"] as? String).flatMap(iso.date)
        var state = AgentState(name: "Gemini", project: project)
        state.working = last["type"] as? String == "user"
        state.started = state.working ? stamp : nil
        state.finished = state.working ? nil : (stamp ?? modified)
        return state
    }
}
