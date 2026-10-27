import SwiftUI

struct IslandRootView: View {
    @ObservedObject var model: IslandModel
    @AppStorage(Prefs.menuBarVeil) private var veil = true

    /// How far past the island's edges the menu bar text fades out.
    private static let feather: CGFloat = 46

    var body: some View {
        let state = model.state
        let shape = NotchShape(topRadius: model.topRadius, bottomRadius: model.bottomRadius, detached: model.detached)
        // Content is laid out at its *final* size and revealed by the animating shape,
        // so text never reflows mid-morph.
        let g = model.target(for: state, includeHover: state == .compact(.claude))

        ZStack(alignment: .top) {
            IslandContent(model: model, state: state)
                .frame(width: g.width + 2 * g.top, height: g.height, alignment: .top)
                .id(state.contentKey + (model.videoPinned && state == .compact(.call) ? ".pinned" : ""))
                .transition(.island)
        }
        .frame(width: model.width + 2 * model.topRadius, height: model.height, alignment: .top)
        .background(Color.black)
        .clipShape(shape)
        .shadow(color: .black.opacity(model.shadow), radius: 22, x: 0, y: 10)
        // Tucks up into the top edge rather than just fading, like the island on iPhone.
        .scaleEffect(model.vanished ? 0.7 : 1, anchor: .top)
        .blur(radius: model.vanished ? 8 : 0)
        .opacity(model.vanished ? 0 : 1)
        .contentShape(shape)
        .onTapGesture { model.click() }
        .overlay(alignment: .topTrailing) {
            if let secondary = model.secondaryActivity {
                SecondaryBubble(model: model, activity: secondary)
                    .offset(x: model.notch.height + 6, y: model.detached ? 0 : 1)
                    .transition(.bubble)
            }
        }
        .background(alignment: .top) { menuBarVeil }
        // Asymmetric wings: shift the whole island so the camera gap stays centred.
        .offset(x: model.xOffset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }
}

extension IslandRootView {
    /// Once the island grows past the hardware notch, the menu bar items it reaches are
    /// blurred into the bar with a feathered edge instead of being sliced in half.
    @ViewBuilder fileprivate var menuBarVeil: some View {
        if !model.detached, veil, !SnapshotRenderer.isRendering {
            let width = model.width + 2 * model.topRadius + 2 * Self.feather
            let f = Self.feather / max(width, 1)
            MenuBarBlur()
                .frame(width: width, height: model.notch.height)
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0), .init(color: .black, location: f),
                            .init(color: .black, location: 1 - f), .init(color: .clear, location: 1),
                        ],
                        startPoint: .leading, endPoint: .trailing)
                )
                .opacity(model.width > model.notch.width + 2 ? 1 : 0)
                .animation(Motion.content, value: model.width > model.notch.width + 2)
                .allowsHitTesting(false)
        }
    }
}

private struct IslandContent: View {
    @ObservedObject var model: IslandModel
    let state: IslandState

    var body: some View {
        switch state {
        case .idle:
            if model.showsCharging {
                Wings(notch: model.notch, inset: 6) {
                    ChargingBolt()
                } trailing: {
                    EmptyView()
                }
                .environment(\.wingWidths, IslandModel.chargingWings)
            } else {
                Color.clear
            }
        case .compact(let a):
            CompactView(model: model, activity: a)
                .environment(\.wingWidths, model.wingWidths(for: a.page))
        case .glance(let page):
            GlanceView(model: model, page: page)
                .environment(\.wingWidths, model.wingWidths(for: page))
        case .transient(.hud(let kind, let value, let muted)):
            HUDView(notch: model.notch, inset: 6, kind: kind, value: value, muted: muted)
        case .transient(.notice(let n)):
            NoticeView(model: model, kind: n.kind)
        case .expanded(let page):
            ExpandedView(model: model, page: page)
        }
    }
}

// MARK: - Compact live activities

private struct CompactView: View {
    @ObservedObject var model: IslandModel
    let activity: Activity

    var body: some View {
        switch activity {
        case .nowPlaying: NowPlayingCompact(np: model.services.nowPlaying, notch: model.notch)
        case .flow: FlowCompact(flow: model.services.flow, notch: model.notch)
        case .claude:
            AICompact(claude: model.services.claude, codex: model.services.codex, gemini: model.services.gemini,
                      notch: model.notch, hovering: model.hovering, charging: model.showsCharging)
        case .call:
            CallCompact(call: model.services.call, notch: model.notch, pinned: model.videoPinned) { model.toggleVideoPin() }
        }
    }
}

struct NowPlayingCompact: View {
    @ObservedObject var np: NowPlayingService
    let notch: CGSize
    @AppStorage(Prefs.visualizer) private var visualizer = true
    @AppStorage(Prefs.artworkTint) private var artworkTint = true

    var body: some View {
        Wings(notch: notch, inset: 6) {
            ArtworkView(image: np.artwork, size: 22)
                .scaleEffect(np.isPlaying ? 1 : 0.86)
                .opacity(np.isPlaying ? 1 : 0.8)
                .animation(Motion.lift, value: np.isPlaying)
        } trailing: {
            if visualizer {
                Visualizer(playing: np.isPlaying, tint: artworkTint ? np.accent : .white)
            } else {
                Image(systemName: np.isPlaying ? "pause.fill" : "play.fill")
                    .font(.island(12, .semibold)).foregroundStyle(.white.opacity(0.85))
                    .contentTransition(.symbolEffect(.replace))
            }
        }
    }
}

struct FlowCompact: View {
    @ObservedObject var flow: FlowTimer
    let notch: CGSize

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            Wings(notch: notch, inset: 6) {
                ProgressRing(progress: flow.progress(at: ctx.date), tint: flow.phase.tint, lineWidth: 2.4)
                    .frame(width: 17, height: 17)
                    .opacity(flow.isRunning ? 1 : 0.55)
            } trailing: {
                Text(Format.clock(flow.remaining(at: ctx.date)))
                    .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(flow.phase.tint)
                    .contentTransition(.numericText(countsDown: true))
                    .opacity(flow.isRunning ? 1 : 0.55)
            }
        }
    }
}

struct ClaudeCompact: View {
    @ObservedObject var claude: ClaudeMonitor
    let notch: CGSize
    let hovering: Bool
    var charging = false

    var body: some View {
        VStack(spacing: 0) {
            Wings(notch: notch, inset: 6) {
                if charging { ChargingBolt() } else { ClaudeGlyph(size: 15) }
            } trailing: {
                Spinner(tint: ClaudeMonitor.tint).frame(width: 15, height: 15)
            }
            if hovering {
                HStack(spacing: 5) {
                    Image(systemName: "hourglass").font(.island(10, .semibold))
                    Text(summary).font(.island(11.5, .medium)).lineLimit(1)
                }
                .foregroundStyle(.white.opacity(0.72))
                .frame(height: 22)
                .transition(.opacity.combined(with: .offset(y: -6)))
            }
        }
        .animation(Motion.lift, value: hovering)
    }

    private var summary: String {
        let s = claude.current
        var parts = [s?.project ?? "Claude", ClaudeMonitor.describe(s)]
        if let start = s?.promptStarted, s?.working == true { parts.append(Format.clock(Date().timeIntervalSince(start))) }
        return parts.joined(separator: " · ")
    }
}

/// The working assistant in compact form: Claude first, then Codex, then Gemini.
struct AICompact: View {
    @ObservedObject var claude: ClaudeMonitor
    @ObservedObject var codex: CodexMonitor
    @ObservedObject var gemini: GeminiMonitor
    let notch: CGSize
    let hovering: Bool
    var charging = false

    var body: some View {
        if claude.isWorking && Prefs.bool(Prefs.claudeEnabled) {
            ClaudeCompact(claude: claude, notch: notch, hovering: hovering, charging: charging)
        } else if let agent = working {
            VStack(spacing: 0) {
                Wings(notch: notch, inset: 6) {
                    if charging { ChargingBolt() } else { AgentGlyph(name: agent.name, size: 15) }
                } trailing: {
                    Spinner(tint: AgentGlyph.tint(agent.name)).frame(width: 15, height: 15)
                }
                if hovering {
                    Text([agent.project ?? agent.name, agent.activity ?? "Thinking…"].joined(separator: " · "))
                        .font(.island(11.5, .medium)).lineLimit(1)
                        .foregroundStyle(.white.opacity(0.72))
                        .frame(height: 22)
                        .transition(.opacity.combined(with: .offset(y: -6)))
                }
            }
            .animation(Motion.lift, value: hovering)
        } else {
            ClaudeCompact(claude: claude, notch: notch, hovering: hovering, charging: charging)
        }
    }

    private var working: AgentState? {
        if Prefs.bool(Prefs.aiCodex), let x = codex.state, x.working { return x }
        if Prefs.bool(Prefs.aiGemini), let g = gemini.state, g.working { return g }
        return nil
    }
}

/// The charging mark of the folded island.
struct ChargingBolt: View {
    var body: some View {
        Image(systemName: "bolt.fill")
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(.green)
            .transition(.opacity.combined(with: .scale(scale: 0.6)))
    }
}

/// The mark of an assistant other than Claude, in its own colour.
struct AgentGlyph: View {
    let name: String
    var size: CGFloat
    var active = false

    static func tint(_ name: String) -> Color {
        switch name {
        case "Codex": return Color(white: 0.92)
        case "Antigravity": return Color(red: 0.42, green: 0.62, blue: 1.0)
        default: return Color(red: 0.36, green: 0.55, blue: 1.0)  // Gemini blue
        }
    }

    static func symbol(_ name: String) -> String {
        switch name {
        case "Codex": return "hexagon.fill"
        case "Antigravity": return "arrow.up.circle.fill"
        default: return "sparkles"
        }
    }

    var body: some View {
        Image(systemName: Self.symbol(name))
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(Self.tint(name))
            .symbolEffect(.pulse, options: .repeating, isActive: active)
    }
}

struct ClaudeGlyph: View {
    var size: CGFloat
    var active = false

    var body: some View {
        Image(systemName: "sparkle")
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(ClaudeMonitor.tint)
            .symbolEffect(.pulse, options: .repeating, isActive: active)
    }
}

/// Second live activity, detached into its own bubble like the iPhone split island.
private struct SecondaryBubble: View {
    @ObservedObject var model: IslandModel
    let activity: Activity

    var body: some View {
        let d = model.notch.height - 2
        ZStack {
            Circle().fill(.black)
            switch activity {
            case .nowPlaying:
                BubbleArt(np: model.services.nowPlaying, size: d - 8)
            case .flow:
                BubbleFlow(flow: model.services.flow).frame(width: d - 12, height: d - 12)
            case .claude:
                Spinner(tint: ClaudeMonitor.tint, lineWidth: 2.2).frame(width: d - 12, height: d - 12)
            case .call:
                CallBubble(call: model.services.call)
            }
        }
        .frame(width: d, height: d)
        .contentShape(Circle())
        .onTapGesture { model.clickSecondary() }
    }
}

private struct BubbleArt: View {
    @ObservedObject var np: NowPlayingService
    let size: CGFloat
    var body: some View {
        ArtworkView(image: np.artwork, size: size).clipShape(Circle())
    }
}

private struct BubbleFlow: View {
    @ObservedObject var flow: FlowTimer
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            ProgressRing(progress: flow.progress(at: ctx.date), tint: flow.phase.tint, lineWidth: 2.2)
        }
    }
}

// MARK: - HUD

struct HUDView: View {
    let notch: CGSize
    let inset: CGFloat
    let kind: HUDKind
    let value: Double
    let muted: Bool

    @AppStorage(Prefs.hudStyle) private var style = "glow"
    @AppStorage(Prefs.hudSpeed) private var speed = "smooth"
    @AppStorage(Prefs.hudShowPercent) private var showPercent = false
    @AppStorage(Prefs.hudScaleSymbol) private var scaleSymbol = true

    var body: some View {
        let shown = muted ? 0 : value
        Wings(notch: notch, inset: inset) {
            symbol
                .font(.island(14, .semibold))
                .foregroundStyle(.white)
                .scaleEffect(scaleSymbol ? 0.82 + 0.26 * shown : 1, anchor: .leading)
                .animation(Motion.hudBar(speed), value: shown)
                .frame(width: 26, alignment: .leading)
        } trailing: {
            HStack(spacing: 8) {
                if showPercent {
                    Text("\(Int((shown * 100).rounded()))")
                        .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.85))
                        .contentTransition(.numericText(value: shown))
                        .animation(Motion.hudBar(speed), value: shown)
                }
                HUDBar(value: shown, style: style, speed: speed)
                    .frame(width: showPercent ? 58 : 78)
            }
        }
    }

    @ViewBuilder private var symbol: some View {
        switch kind {
        case .volume:
            if muted || value <= 0.001 {
                Image(systemName: "speaker.slash.fill").contentTransition(.symbolEffect(.replace))
            } else {
                Image(systemName: "speaker.wave.3.fill", variableValue: value).contentTransition(.symbolEffect(.replace))
            }
        case .brightness:
            Image(systemName: value < 0.35 ? "sun.min.fill" : "sun.max.fill").contentTransition(.symbolEffect(.replace))
        }
    }
}

struct HUDBar: View {
    let value: Double
    let style: String
    let speed: String

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.16))
                Capsule()
                    .fill(fill)
                    .frame(width: max(0, geo.size.width * value))
                    // Glow: a lit filament, brightest at its leading edge, with a soft halo.
                    .shadow(color: style == "glow" ? .white.opacity(0.85) : .clear, radius: 3)
                    .shadow(color: style == "glow" ? .white.opacity(0.45) : .clear, radius: 9)
            }
        }
        .frame(height: 6)
        .animation(Motion.hudBar(speed), value: value)
    }

    private var fill: AnyShapeStyle {
        switch style {
        case "accent": return AnyShapeStyle(Color(nsColor: .controlAccentColor))
        case "glow":
            return AnyShapeStyle(
                LinearGradient(
                    colors: [.white.opacity(0.35), .white.opacity(0.85), .white],
                    startPoint: .leading, endPoint: .trailing))
        default: return AnyShapeStyle(Color.white)
        }
    }
}

// MARK: - Notices

private struct NoticeView: View {
    @ObservedObject var model: IslandModel
    let kind: NoticeKind
    @State private var unlocked = false

    var body: some View {
        let n = model.notch
        switch kind {
        case .charging(let pct):
            Wings(notch: n, inset: 6) {
                Text("Charging").font(.island(13, .semibold)).foregroundStyle(.white)
            } trailing: {
                HStack(spacing: 5) {
                    Text("\(pct)%").font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit()).foregroundStyle(.green)
                    Image(systemName: "battery.100percent.bolt").font(.island(15)).foregroundStyle(.green)
                        .symbolRenderingMode(.hierarchical)
                        .symbolEffect(.bounce, value: pct)
                }
            }

        case .lowBattery(let pct):
            Card(notch: n, inset: 10) {
                Image(systemName: "battery.25percent").font(.island(24)).foregroundStyle(.red)
            } title: {
                Text("Low Battery")
            } subtitle: {
                Text("\(pct)% remaining")
            }

        case .lowPower(let on):
            Card(notch: n, inset: 10) {
                Image(systemName: "battery.50percent").font(.island(24)).foregroundStyle(.yellow)
            } title: {
                Text("Low Power Mode")
            } subtitle: {
                Text(on ? "On" : "Off")
            }

        case .deviceConnected(_, let symbol, let battery):
            Wings(notch: n, inset: 6) {
                Image(systemName: symbol).font(.island(15, .medium)).foregroundStyle(.white)
                    .symbolEffect(.bounce, value: symbol)
            } trailing: {
                if let level = battery.lowest {
                    ProgressRing(progress: Double(level) / 100, tint: level <= 20 ? .red : .green, lineWidth: 2.6)
                        .frame(width: 17, height: 17)
                } else {
                    Image(systemName: "checkmark.circle.fill").font(.island(15)).foregroundStyle(.green)
                }
            }

        case .deviceDisconnected(_, let symbol):
            Wings(notch: n, inset: 6) {
                Image(systemName: symbol).font(.island(15, .medium)).foregroundStyle(.white.opacity(0.55))
            } trailing: {
                Text("Disconnected").font(.island(12, .medium)).foregroundStyle(.white.opacity(0.55))
            }

        case .focus(_, let symbol, let tint, let active):
            // The mode's own symbol says which Focus it is; colour says on, grey says off.
            Wings(notch: n, inset: 6) {
                Image(systemName: symbol).font(.island(14, .semibold))
                    .foregroundStyle(active ? tint : .white.opacity(0.4))
                    .symbolEffect(.bounce, value: active)
            } trailing: {
                Text(active ? "On" : "Off").font(.island(12.5, .semibold))
                    .foregroundStyle(active ? tint : .white.opacity(0.4))
            }

        case .event(let title, let minutes, let tint):
            Card(notch: n, inset: 10) {
                RoundedRectangle(cornerRadius: 2, style: .continuous).fill(tint).frame(width: 4, height: 30)
            } title: {
                Text(title)
            } subtitle: {
                Text("In \(minutes) min")
            }

        case .unlocked:
            Wings(notch: n, inset: 6) {
                Image(systemName: unlocked ? "lock.open.fill" : "lock.fill")
                    .font(.island(14, .semibold)).foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace.downUp))
            } trailing: {
                EmptyView()
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { withAnimation(Motion.content) { unlocked = true } }
            }

        case .flowPhase(let phase):
            Wings(notch: n, inset: 6) {
                Image(systemName: phase == .focus ? "brain.head.profile" : "cup.and.saucer.fill")
                    .font(.island(14, .semibold)).foregroundStyle(phase.tint)
                    .symbolEffect(.bounce, value: phase)
            } trailing: {
                Text(phase.title).font(.island(12.5, .semibold)).foregroundStyle(phase.tint)
            }

        case .shelfAdded(let count):
            Wings(notch: n, inset: 6) {
                Image(systemName: "tray.and.arrow.down.fill").font(.island(14, .semibold)).foregroundStyle(.white)
            } trailing: {
                Text("+\(count)").font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(.white)
            }

        case .claudeDone(let project):
            Card(notch: n, inset: 10) {
                ZStack(alignment: .bottomTrailing) {
                    ClaudeGlyph(size: 22)
                    Image(systemName: "checkmark.circle.fill").font(.island(11, .bold)).foregroundStyle(.green)
                        .background(Circle().fill(.black).padding(-1)).offset(x: 4, y: 3)
                }
            } title: {
                Text("Claude is done")
            } subtitle: {
                Text(project)
            }

        case .agentDone(let name, let project):
            Card(notch: n, inset: 10) {
                ZStack(alignment: .bottomTrailing) {
                    AgentGlyph(name: name, size: 22)
                    Image(systemName: "checkmark.circle.fill").font(.island(11, .bold)).foregroundStyle(.green)
                        .background(Circle().fill(.black).padding(-1)).offset(x: 4, y: 3)
                }
            } title: {
                Text("\(name) is done")
            } subtitle: {
                Text(project)
            }

        case .claudeWaiting(let project, let message):
            Card(notch: n, inset: 10) {
                ClaudeGlyph(size: 22, active: true)
            } title: {
                Text(message).lineLimit(1)
            } subtitle: {
                Text(project)
            }

        case .claudeUsage(let percent, let window):
            Card(notch: n, inset: 10) {
                ProgressRing(progress: Double(percent) / 100, tint: percent >= 95 ? .red : .orange, lineWidth: 3.5)
                    .frame(width: 24, height: 24)
            } title: {
                Text("\(percent)% of your \(window) limit")
            } subtitle: {
                Text("Claude limit almost reached")
            }
        }
    }
}

/// Taller notice: an icon and two lines under the notch row.
private struct Card<Icon: View, Title: View, Subtitle: View>: View {
    let notch: CGSize
    let inset: CGFloat
    @ViewBuilder var icon: Icon
    @ViewBuilder var title: Title
    @ViewBuilder var subtitle: Subtitle

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: notch.height)
            HStack(spacing: 12) {
                icon.frame(width: 30)
                VStack(alignment: .leading, spacing: 1) {
                    title.font(.island(14, .semibold)).foregroundStyle(.white).lineLimit(1)
                    subtitle.font(.island(12.5)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, inset + 20)
            .frame(maxHeight: .infinity)
            .padding(.bottom, 6)
        }
    }
}
