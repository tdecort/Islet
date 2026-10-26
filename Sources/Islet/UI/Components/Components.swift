import SwiftUI

/// Lays content out on either side of the camera housing: left wing, the notch gap,
/// right wing. `inset` is the shoulder radius of the current shape.
struct Wings<Leading: View, Trailing: View>: View {
    let notch: CGSize
    let inset: CGFloat
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing
    /// Compact states size each wing to its own content (see `IslandModel.wingWidths`).
    @Environment(\.wingWidths) private var widths

    var body: some View {
        if let widths {
            HStack(spacing: 0) {
                leading.frame(width: max(0, widths.leading - 16), alignment: .leading)
                    .padding(.leading, 10).padding(.trailing, 6)
                Color.clear.frame(width: notch.width)
                trailing.frame(width: max(0, widths.trailing - 16), alignment: .trailing)
                    .padding(.leading, 6).padding(.trailing, 10)
            }
            .padding(.horizontal, inset)
            .frame(height: notch.height)
        } else {
            HStack(spacing: 0) {
                leading.frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(width: notch.width)
                trailing.frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, inset + 10)
            .frame(height: notch.height)
        }
    }
}

struct WingWidths: Equatable {
    var leading: CGFloat
    var trailing: CGFloat
}

private struct WingWidthsKey: EnvironmentKey {
    static let defaultValue: WingWidths? = nil
}

extension EnvironmentValues {
    var wingWidths: WingWidths? {
        get { self[WingWidthsKey.self] }
        set { self[WingWidthsKey.self] = newValue }
    }
}

struct ArtworkView: View {
    let image: NSImage?
    let size: CGFloat
    var radius: CGFloat { size * 0.22 }

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                LinearGradient(colors: [Color(white: 0.28), Color(white: 0.16)], startPoint: .top, endPoint: .bottom)
                Image(systemName: "music.note").font(.system(size: size * 0.42, weight: .medium)).foregroundStyle(.white.opacity(0.55))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
    }
}

/// Music waveform. Driven by a paused-when-idle `TimelineView`, so it costs nothing
/// when the track is paused; bars settle into dots like on iPhone.
struct Visualizer: View {
    var playing: Bool
    var tint: Color
    var height: CGFloat = 14
    var bars = 5

    private static let speeds: [Double] = [1.7, 2.35, 1.3, 2.9, 1.95, 2.6]

    var body: some View {
        if SnapshotRenderer.isRendering {
            timeline
        } else {
            LayerBars(playing: playing, tint: tint, bars: bars).frame(width: CGFloat(bars) * 4.6, height: height)
        }
    }

    private var timeline: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !playing)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<bars, id: \.self) { i in
                    Capsule()
                        .fill(tint)
                        .frame(width: 2.6, height: max(2.6, height * (playing ? Self.level(i, t) : 0.18)))
                }
            }
        }
        .frame(height: height)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: playing)
    }

    private static func level(_ i: Int, _ t: Double) -> Double {
        let s = speeds[i % speeds.count]
        let p = Double(i) * 1.37
        let v = 0.52 + 0.28 * sin(t * s * 2.4 + p) + 0.2 * sin(t * s * 5.3 + p * 2.1)
        return min(1, max(0.16, v))
    }
}

/// Scrubbable capsule bar (track position, volume). Thickens under the finger like iOS.
struct ScrubBar: View {
    var value: Double
    var tint: Color = .white
    var onChange: ((Double) -> Void)?
    var onCommit: (Double) -> Void

    @State private var dragValue: Double?
    @State private var active = false

    var body: some View {
        GeometryReader { geo in
            let v = min(1, max(0, dragValue ?? value))
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.16))
                Capsule().fill(tint.opacity(active ? 1 : 0.85)).frame(width: geo.size.width * v)
            }
            .frame(height: active ? 9 : 5)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if !active { withAnimation(Motion.press) { active = true } }
                        let f = min(1, max(0, g.location.x / max(1, geo.size.width)))
                        dragValue = f
                        onChange?(f)
                    }
                    .onEnded { _ in
                        onCommit(dragValue ?? value)
                        withAnimation(Motion.press) { active = false }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { dragValue = nil }
                    }
            )
        }
        .frame(height: 16)
    }
}

struct ProgressRing: View {
    var progress: Double
    var tint: Color
    var lineWidth: CGFloat = 2.6

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.22), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, progress)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

/// Indeterminate spinner: a rotating arc, the one Apple uses for "in progress".
struct Spinner: View {
    var tint: Color
    var lineWidth: CGFloat = 2.4

    var body: some View {
        if SnapshotRenderer.isRendering {
            timeline
        } else {
            LayerSpinner(tint: tint, lineWidth: lineWidth)
        }
    }

    private var timeline: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            ZStack {
                Circle().stroke(tint.opacity(0.18), lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.radians(t.truncatingRemainder(dividingBy: 1) * 2 * .pi))
            }
        }
    }
}

/// Glyph button that dips under the cursor and springs back.
struct PressableStyle: ButtonStyle {
    var highlight = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .background {
                Circle().fill(.white.opacity(configuration.isPressed ? 0.14 : (highlight ? 0.10 : 0)))
                    .padding(-6)
            }
            .scaleEffect(configuration.isPressed ? 0.84 : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

struct IslandButton: View {
    let symbol: String
    var size: CGFloat = 15
    var weight: Font.Weight = .semibold
    var tint: Color = .white
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: weight))
                .foregroundStyle(tint)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: size * 1.9, height: size * 1.7)
        }
        .buttonStyle(PressableStyle())
    }
}

extension Font {
    static func island(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
}

enum Format {
    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    static func until(_ date: Date?) -> String {
        guard let date else { return "—" }
        let m = max(0, Int(date.timeIntervalSinceNow / 60))
        if m >= 1440 { return "\(m / 1440)d \(m / 60 % 24)h" }
        if m >= 60 { return "\(m / 60)h \(m % 60)m" }
        return "\(m) min"
    }

    /// Dates and times follow the Mac's own language and 12/24-hour setting.
    /// Marketing renders pin it to US English.
    nonisolated(unsafe) static var locale = Locale.autoupdatingCurrent {
        didSet {
            time.locale = locale
            time.setLocalizedDateFormatFromTemplate("jmm")
            weekday.locale = locale
            weekday.setLocalizedDateFormatFromTemplate("EEE")
        }
    }

    static let time: DateFormatter = {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.setLocalizedDateFormatFromTemplate("jmm")
        return f
    }()

    static let weekday: DateFormatter = {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.setLocalizedDateFormatFromTemplate("EEE")
        return f
    }()
}
