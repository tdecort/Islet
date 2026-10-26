import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ExpandedView: View {
    @ObservedObject var model: IslandModel
    let page: Page
    var body: some View {
        VStack(spacing: 0) {
            Wings(notch: model.notch, inset: 12) {
                // Pages are switched with a two-finger swipe; no tab bar.
                HeaderBattery(battery: model.services.battery)
            } trailing: {
                Button {
                    AppDelegate.shared?.showSettings()
                } label: {
                    Image(systemName: "gearshape.fill").font(.island(12, .semibold)).foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(PressableStyle())
            }
            ZStack {
                pageView
                    .id(page)
                    .transition(.page(forward: model.pageForward))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // A click on the page itself (not one of its controls) opens the app behind it.
            .contentShape(Rectangle())
            .onTapGesture { model.openApp(for: page) }
            .padding(.horizontal, 12 + 16)
            .padding(.bottom, 12)
        }
    }

    @ViewBuilder private var pageView: some View {
        let s = model.services
        switch page {
        case .nowPlaying: NowPlayingPage(np: s.nowPlaying)
        case .claude: AIPage(claude: s.claude, codex: s.codex, gemini: s.gemini)
        case .calendar: CalendarPage(calendar: s.calendar)
        case .weather: WeatherPage(weather: s.weather)
        case .flow: FlowPage(flow: s.flow, model: model)
        case .shelf: ShelfPage(shelf: s.shelf, targeting: model.dropTargeting, zone: model.dropZone)
        case .call: CallPage(call: s.call, pinned: model.videoPinned) { model.toggleVideoPin() }
        }
    }
}

private struct HeaderBattery: View {
    @ObservedObject var battery: BatteryMonitor
    @AppStorage(Prefs.batteryInHeader) private var showBattery = true

    var body: some View {
        if showBattery, battery.hasBattery {
            HStack(spacing: 4) {
                Image(systemName: battery.symbol).font(.island(13)).symbolRenderingMode(.hierarchical)
                Text("\(battery.percent)%").font(.system(size: 11.5, weight: .semibold, design: .rounded).monospacedDigit())
            }
            .foregroundStyle(battery.tint == .white ? .white.opacity(0.8) : battery.tint)
        }
    }
}

// MARK: - Now Playing

private struct NowPlayingPage: View {
    @ObservedObject var np: NowPlayingService
    @AppStorage(Prefs.visualizer) private var visualizer = true
    @AppStorage(Prefs.artworkTint) private var artworkTint = true

    var body: some View {
        if let track = np.track {
            VStack(spacing: 4) {
                HStack(spacing: 12) {
                    ArtworkView(image: np.artwork, size: 46)
                        .scaleEffect(np.isPlaying ? 1 : 0.9)
                        .shadow(color: .black.opacity(0.5), radius: 8, y: 3)
                        .animation(Motion.openHeight, value: np.isPlaying)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title).font(.island(13.5, .semibold)).foregroundStyle(.white).lineLimit(1)
                        Text(track.artist).font(.island(12.5)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                    }
                    .id(track.title)
                    .transition(.opacity)
                    Spacer(minLength: 8)
                    if visualizer {
                        Visualizer(playing: np.isPlaying, tint: artworkTint ? np.accent : .white, height: 15)
                    }
                }
                TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                    let elapsed = np.elapsed(at: ctx.date)
                    HStack(spacing: 10) {
                        Text(Format.clock(elapsed)).frame(width: 36, alignment: .leading)
                        ScrubBar(value: elapsed / track.duration, tint: .white.opacity(0.7)) { np.seek(to: $0) }
                        Text("-" + Format.clock(track.duration - elapsed)).frame(width: 40, alignment: .trailing)
                    }
                    .font(.system(size: 10.5, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.5))
                }
                HStack {
                    IslandButton(symbol: "shuffle", size: 12.5, tint: np.shuffle ? .white : .white.opacity(0.45)) { np.toggleShuffle() }
                    Spacer()
                    IslandButton(symbol: "backward.fill", size: 16) { np.previous() }
                    Spacer()
                    IslandButton(symbol: np.isPlaying ? "pause.fill" : "play.fill", size: 21) { np.playPause() }
                    Spacer()
                    IslandButton(symbol: "forward.fill", size: 16) { np.next() }
                    Spacer()
                    IslandButton(symbol: "laptopcomputer", size: 13, weight: .regular, tint: .white.opacity(0.6)) { np.openPlayer() }
                }
                .padding(.horizontal, 4)
            }
        } else {
            EmptyPlayer()
        }
    }
}

private struct EmptyPlayer: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note").font(.island(26, .medium)).foregroundStyle(.white.opacity(0.35))
            Text("Nothing playing").font(.island(13, .medium)).foregroundStyle(.white.opacity(0.5))
            HStack(spacing: 10) {
                ForEach(NowPlayingService.Source.allCases.filter(\.isInstalled), id: \.rawValue) { src in
                    Button {
                        if let url = src.appURL { NSWorkspace.shared.openApplication(at: url, configuration: .init()) }
                    } label: {
                        Text("Open \(src.name)").font(.island(12, .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(.white.opacity(0.12)))
                    }
                    .buttonStyle(PressableStyle())
                }
            }
        }
    }
}

// MARK: - Claude

/// Claude on top while it is in use; Codex and Gemini below, one line each, only when in
/// use. When only another assistant is in use, it takes Claude's place.
private struct AIPage: View {
    @ObservedObject var claude: ClaudeMonitor
    @ObservedObject var codex: CodexMonitor
    @ObservedObject var gemini: GeminiMonitor

    var body: some View {
        let lineup = AILineup.make(
            claudeOn: Prefs.bool(Prefs.claudeEnabled), claudeWorking: claude.isWorking, claudeLastActive: claude.lastActive,
            agents: [Prefs.bool(Prefs.aiCodex) ? codex.state : nil, Prefs.bool(Prefs.aiGemini) ? gemini.state : nil].compactMap { $0 })
        VStack(alignment: .leading, spacing: 12) {
            if lineup.claudeLeads {
                ClaudePage(claude: claude)
                ForEach(lineup.others, id: \.name) { AgentRow(agent: $0) }
            } else {
                AgentHeader(agent: lineup.others.first ?? placeholder)
                ForEach(lineup.others.dropFirst(), id: \.name) { AgentRow(agent: $0) }
            }
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }

    private var placeholder: AgentState {
        AgentState(name: Prefs.bool(Prefs.aiCodex) ? "Codex" : "Gemini")
    }
}

/// What an assistant is doing, said in a few words.
private func agentStatus(_ a: AgentState) -> String {
    if a.working { return a.activity ?? "Thinking…" }
    return a.finished == nil ? "No recent session" : "Done"
}

/// The run time while working, or how long ago the last run ended.
private struct AgentClock: View {
    let agent: AgentState
    var size: CGFloat = 13

    var body: some View {
        if agent.working, let start = agent.started {
            HStack(spacing: 6) {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(Format.clock(ctx.date.timeIntervalSince(start)))
                        .font(.system(size: size, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(AgentGlyph.tint(agent.name))
                }
                Spinner(tint: AgentGlyph.tint(agent.name), lineWidth: 2).frame(width: size - 1, height: size - 1)
            }
        } else if let limit = agent.limits.max(by: { $0.utilization < $1.utilization }) {
            Text("\(limit.label) \(Int(limit.utilization))%")
                .font(.system(size: 11.5, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(limit.utilization >= 90 ? .red : limit.utilization >= 75 ? .orange : .white.opacity(0.45))
        } else if let done = agent.finished {
            Text(done.formatted(.relative(presentation: .named).locale(Format.locale)))
                .font(.island(11)).foregroundStyle(.white.opacity(0.4))
        }
    }
}

/// An assistant as the page's main line, when Claude is turned off.
private struct AgentHeader: View {
    let agent: AgentState

    var body: some View {
        HStack(spacing: 10) {
            AgentGlyph(name: agent.name, size: 17, active: agent.working)
            VStack(alignment: .leading, spacing: 1) {
                Text(agentStatus(agent)).font(.island(14, .semibold)).foregroundStyle(.white).lineLimit(1)
                Text([agent.name, agent.project].compactMap { $0 }.joined(separator: " · "))
                    .font(.island(12)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
            }
            Spacer(minLength: 8)
            AgentClock(agent: agent, size: 15)
        }
    }
}

/// One more assistant, on a single line under Claude.
private struct AgentRow: View {
    let agent: AgentState

    var body: some View {
        HStack(spacing: 8) {
            AgentGlyph(name: agent.name, size: 12, active: agent.working)
                .frame(width: 17)
            Text(agent.name).font(.island(12, .semibold)).foregroundStyle(.white.opacity(0.85))
            Text([agent.project, agentStatus(agent)].compactMap { $0 }.joined(separator: " · "))
                .font(.island(11.5)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
            Spacer(minLength: 6)
            AgentClock(agent: agent)
        }
        .frame(height: 22)
    }
}

private struct ClaudePage: View {
    @ObservedObject var claude: ClaudeMonitor

    var body: some View {
        let current = claude.current
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ClaudeGlyph(size: 17, active: current?.working == true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(ClaudeMonitor.describe(current))
                        .font(.island(14, .semibold))
                        .foregroundStyle(current?.waiting == true ? .orange : .white)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                    Text(subtitle(current)).font(.island(12)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                }
                Spacer(minLength: 8)
                RunTime(session: current)
            }
            .animation(Motion.content, value: ClaudeMonitor.describe(current))
            if claude.session != nil || claude.weekly != nil {
                VStack(spacing: 8) {
                    if let s = claude.session { LimitRow(label: "Session", window: s) }
                    if let w = claude.weekly { LimitRow(label: "Week", window: w) }
                }
            }
        }
    }

    private func subtitle(_ s: ClaudeMonitor.Session?) -> String {
        guard let s else { return claude.hooksInstalled ? "Claude Code" : "Turn on the integration in Settings" }
        if s.working || s.waiting { return s.project }
        if let finished = s.finished {
            return "\(s.project) · \(finished.formatted(.relative(presentation: .named).locale(Format.locale)))"
        }
        return s.project
    }
}

/// Time since the prompt was sent, live while Claude works; the run's length once done.
private struct RunTime: View {
    let session: ClaudeMonitor.Session?

    var body: some View {
        if let s = session, s.working, let start = s.promptStarted {
            HStack(spacing: 7) {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(Format.clock(ctx.date.timeIntervalSince(start)))
                        .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(ClaudeMonitor.tint)
                        .contentTransition(.numericText())
                }
                Spinner(tint: ClaudeMonitor.tint, lineWidth: 2).frame(width: 14, height: 14)
            }
        } else if let s = session, let run = s.lastRun {
            Text(Format.clock(run))
                .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white.opacity(0.45))
        }
    }
}

/// One limit on one line: name and share used on the left, reset on the right, bar below.
private struct LimitRow: View {
    let label: String
    let window: ClaudeMonitor.Window

    var body: some View {
        let tint = window.pace == .good ? ClaudeMonitor.tint : window.pace.tint
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(label) \(Int(window.utilization))%").font(.island(11.5, .semibold)).foregroundStyle(.white.opacity(0.85))
                Spacer()
                Text("resets in \(Format.until(window.resetsAt))").font(.island(11)).foregroundStyle(.white.opacity(0.4))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.1))
                    Capsule().fill(tint).frame(width: geo.size.width * min(1, window.utilization / 100))
                }
            }
            .frame(height: 5)
        }
    }
}

// MARK: - Calendar

private struct CalendarPage: View {
    @ObservedObject var calendar: CalendarService

    var body: some View {
        HStack(alignment: .top, spacing: 22) {
            VStack(alignment: .leading, spacing: -2) {
                Text(Date().formatted(.dateTime.weekday(.wide).locale(Format.locale)).capitalized)
                    .font(.island(12, .semibold)).foregroundStyle(.red)
                Text(Date().formatted(.dateTime.day()))
                    .font(.system(size: 32, weight: .regular)).foregroundStyle(.white)
                Text(Date().formatted(.dateTime.month(.wide).locale(Format.locale)).capitalized)
                    .font(.island(12)).foregroundStyle(.white.opacity(0.5))
            }
            .frame(width: 92, alignment: .leading)

            VStack(alignment: .leading, spacing: 8) {
                switch calendar.access {
                case .granted:
                    if calendar.events.isEmpty {
                        Text("No upcoming events").font(.island(13)).foregroundStyle(.white.opacity(0.5)).padding(.top, 6)
                    } else {
                        ForEach(calendar.events.prefix(3)) { e in EventRow(event: e) }
                    }
                case .denied:
                    Text("Calendar access denied.\nAllow Islet in System Settings › Privacy.")
                        .font(.island(12)).foregroundStyle(.white.opacity(0.5))
                case .unknown:
                    Text("Requesting calendar access…").font(.island(12)).foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.top, 8)
    }
}

private struct EventRow: View {
    let event: CalendarService.Event

    var body: some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous).fill(event.tint).frame(width: 3, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title).font(.island(13, .semibold)).foregroundStyle(.white).lineLimit(1)
                Text(when).font(.island(11.5)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
            }
        }
    }

    private var when: String {
        let range = "\(Format.time.string(from: event.start)) – \(Format.time.string(from: event.end))"
        if event.start <= Date() { return "Now · \(range)" }
        if !Calendar.current.isDateInToday(event.start) { return "Tomorrow · \(range)" }
        return range + (event.location.map { " · \($0)" } ?? "")
    }
}

// MARK: - Weather

private struct WeatherPage: View {
    @ObservedObject var weather: WeatherService

    var body: some View {
        if let r = weather.report {
            let now = WeatherService.describe(r.code, day: r.isDay)
            VStack(spacing: 6) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: -4) {
                        Text(r.place).font(.island(14, .semibold)).foregroundStyle(.white)
                        Text("\(Int(r.temperature.rounded()))°").font(.system(size: 32, weight: .light)).foregroundStyle(.white)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        Image(systemName: now.symbol).symbolRenderingMode(.multicolor).font(.island(20))
                        Text(now.label).font(.island(12.5, .semibold)).foregroundStyle(.white.opacity(0.85))
                        Text("H:\(Int(r.high.rounded()))°  L:\(Int(r.low.rounded()))°").font(.island(12)).foregroundStyle(.white.opacity(0.5))
                    }
                }
                HStack {
                    ForEach(r.days) { d in
                        VStack(spacing: 5) {
                            Text(Format.weekday.string(from: d.date).capitalized).font(.island(11.5, .medium)).foregroundStyle(.white.opacity(0.5))
                            Image(systemName: WeatherService.describe(d.code).symbol).symbolRenderingMode(.multicolor).font(.island(14))
                                .frame(height: 16)
                            Text("\(Int(d.high.rounded()))°").font(.island(12.5, .semibold)).foregroundStyle(.white)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        } else {
            VStack(spacing: 8) {
                switch weather.status {
                case .needsLocation:
                    Image(systemName: "location.slash.fill").font(.island(20)).foregroundStyle(.white.opacity(0.4))
                    Text("Location unavailable — pick a city in Settings.")
                        .font(.island(12)).foregroundStyle(.white.opacity(0.5)).multilineTextAlignment(.center)
                case .failed(let why):
                    Image(systemName: "cloud.fill").font(.island(20)).foregroundStyle(.white.opacity(0.4))
                    Text(why).font(.island(12)).foregroundStyle(.white.opacity(0.5))
                default:
                    ProgressView().controlSize(.small)
                }
            }
        }
    }
}

// MARK: - Flow

private struct FlowPage: View {
    @ObservedObject var flow: FlowTimer
    @ObservedObject var model: IslandModel
    @AppStorage(Prefs.flowRounds) private var rounds = 4
    @AppStorage(Prefs.flowFocus) private var focusMinutes = 25
    @State private var draft = ""
    @FocusState private var typing: Bool

    var body: some View {
        HStack(spacing: 20) {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                ZStack {
                    // Only the ring glides from second to second; the time and the input
                    // field swap instantly.
                    ProgressRing(progress: flow.progress(at: ctx.date), tint: flow.phase.tint, lineWidth: 5.5)
                        .animation(.linear(duration: 1), value: ctx.date)
                    if model.timerEditing {
                        durationField
                    } else {
                        Text(Format.clock(flow.remaining(at: ctx.date)))
                            .font(.system(size: 21, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(.white)
                            .contentTransition(.numericText(countsDown: true))
                            .animation(.smooth(duration: 0.3), value: ctx.date)
                            .contentShape(Rectangle())
                            // Click the time to type a new duration (only before a session starts).
                            .onTapGesture { if !flow.isActive { beginEditing() } }
                    }
                }
                .frame(width: 72, height: 72)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(flow.phase.title).font(.island(17, .semibold)).foregroundStyle(flow.phase.tint)
                if flow.isActive {
                    HStack(spacing: 5) {
                        ForEach(0..<max(1, rounds), id: \.self) { i in
                            Circle().fill(i < flow.completed % max(1, rounds) ? flow.phase.tint : .white.opacity(0.18))
                                .frame(width: 7, height: 7)
                        }
                        Text("\(flow.completed) session\(flow.completed == 1 ? "" : "s")")
                            .font(.island(11.5)).foregroundStyle(.white.opacity(0.45)).padding(.leading, 4)
                    }
                } else {
                    Text(model.timerEditing ? "Minutes, then ↩︎" : "Click the time to change it")
                        .font(.island(11.5)).foregroundStyle(.white.opacity(0.45))
                }
                HStack(spacing: 14) {
                    Button {
                        if model.timerEditing { commit() }
                        flow.toggle()
                    } label: {
                        Image(systemName: flow.isRunning ? "pause.fill" : "play.fill")
                            .font(.island(17, .semibold)).foregroundStyle(.black)
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(flow.phase.tint))
                    }
                    .buttonStyle(PressableStyle())
                    IslandButton(symbol: "forward.end.fill", size: 15, tint: .white.opacity(0.7)) { flow.skip() }
                    IslandButton(symbol: "arrow.counterclockwise", size: 15, tint: .white.opacity(0.7)) { flow.reset() }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var durationField: some View {
        // Empty field with the current length as a hint: typing replaces it at once.
        TextField("", text: $draft, prompt: Text("\(focusMinutes)").foregroundStyle(.white.opacity(0.3)))
            .textFieldStyle(.plain)
            .multilineTextAlignment(.center)
            .font(.system(size: 21, weight: .semibold, design: .rounded).monospacedDigit())
            .foregroundStyle(.white)
            .frame(width: 56)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(0.12)))
            .focused($typing)
            .onChange(of: draft) { draft = String(draft.filter(\.isNumber).prefix(3)) }
            .onSubmit(commit)
            .onExitCommand { model.endTimerEdit() }
            .onAppear { typing = true }
    }

    private func beginEditing() {
        draft = ""
        model.beginTimerEdit()
    }

    private func commit() {
        if let minutes = Int(draft), minutes > 0 { flow.setFocusMinutes(min(minutes, 600)) }  // empty keeps the current one
        model.endTimerEdit()
    }
}

// MARK: - Shelf (drop zones)

private struct ShelfPage: View {
    @ObservedObject var shelf: ShelfStore
    let targeting: Bool
    /// The zone under a file being dragged, reported by the island's AppKit drop target.
    let zone: DropZone?
    private var overShelf: Bool { zone == .shelf }
    private var overAirDrop: Bool { zone == .airDrop }

    var body: some View {
        HStack(spacing: 12) {
            zone(active: overShelf || (targeting && shelf.items.isEmpty)) {
                if shelf.items.isEmpty {
                    Label(targeting ? "Drop here" : "Drag files to the notch", systemImage: "tray.and.arrow.down.fill")
                        .font(.island(12.5, .medium)).foregroundStyle(.white.opacity(0.55))
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        shelfRow
                    }
                    // Image renders cannot draw scroll views; marketing shots show the row directly.
                    .opacity(SnapshotRenderer.isRendering ? 0 : 1)
                    .overlay { if SnapshotRenderer.isRendering { shelfRow } }
                    .overlay(alignment: .topTrailing) {
                        Button {
                            shelf.clear()
                        } label: {
                            Image(systemName: "xmark.circle.fill").font(.island(13)).foregroundStyle(.white.opacity(0.4))
                        }
                        .buttonStyle(PressableStyle())
                        .padding(6)
                    }
                }
            }

            zone(active: overAirDrop) {
                VStack(spacing: 6) {
                    Image(systemName: "airplayaudio").hidden().overlay {
                        Image(systemName: "dot.radiowaves.up.forward").font(.island(22, .medium))
                            .symbolEffect(.variableColor.iterative, isActive: overAirDrop)
                    }
                    Text("AirDrop").font(.island(12, .semibold))
                }
                .foregroundStyle(overAirDrop ? .white : .white.opacity(0.55))
            }
            .frame(width: IslandModel.airDropZoneWidth)
        }
        .padding(.top, 4)
    }

    private var shelfRow: some View {
        HStack(spacing: 10) {
            ForEach(shelf.items, id: \.self) { url in ShelfItem(url: url, shelf: shelf) }
        }
        .padding(.horizontal, 10)
    }

    private func zone<C: View>(active: Bool, @ViewBuilder _ content: () -> C) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.white.opacity(active ? 0.1 : 0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(.white.opacity(active ? 0.45 : 0.14), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])))
            )
            .scaleEffect(active ? 1.02 : 1)
            .animation(Motion.lift, value: active)
    }
}

private struct ShelfItem: View {
    let url: URL
    let shelf: ShelfStore

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 40, height: 40)
            Text(url.lastPathComponent).font(.island(10.5)).foregroundStyle(.white.opacity(0.75)).lineLimit(1).truncationMode(.middle)
                .frame(width: 64)
        }
        // Drag out, double-click and right-click are handled in AppKit: SwiftUI's drag
        // source doesn't start reliably from a panel that never becomes active.
        .overlay { if !SnapshotRenderer.isRendering { FileDragSource(url: url, shelf: shelf) } }
        .transition(.scale.combined(with: .opacity))
    }
}

private struct FileDragSource: NSViewRepresentable {
    let url: URL
    let shelf: ShelfStore

    func makeNSView(context: Context) -> FileDragView { FileDragView(url: url, shelf: shelf) }

    func updateNSView(_ view: FileDragView, context: Context) {
        view.url = url
    }
}

/// A shelf file you can drag into any app (Messages, Mail, Finder…), double-click to
/// open, or right-click for more.
final class FileDragView: NSView, NSDraggingSource {
    var url: URL
    private let shelf: ShelfStore
    private var mouseDown: NSEvent?

    init(url: URL, shelf: ShelfStore) {
        self.url = url
        self.shelf = shelf
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            NSWorkspace.shared.open(url)
            return
        }
        mouseDown = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDown else { return }
        let a = start.locationInWindow, b = event.locationInWindow
        guard hypot(b.x - a.x, b.y - a.y) > 3 else { return }
        mouseDown = nil
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(bounds, contents: NSWorkspace.shared.icon(forFile: url.path))
        AppDelegate.shared?.model.setDraggingOut(true)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) { mouseDown = nil }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .generic] : .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        AppDelegate.shared?.model.setDraggingOut(false)
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        for (title, action) in [("Open", #selector(open)), ("Show in Finder", #selector(reveal)), ("AirDrop", #selector(airDrop))] {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Remove from Shelf", action: #selector(remove), keyEquivalent: "").target = self
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func open() { NSWorkspace.shared.open(url) }
    @objc private func reveal() { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    @objc private func airDrop() { shelf.airDrop([url]) }
    @objc private func remove() { shelf.remove(url) }
}
