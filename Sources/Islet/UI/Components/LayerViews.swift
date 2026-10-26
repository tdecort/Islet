import AppKit
import SwiftUI

/// Continuous animations (spinner, waveform) run as Core Animation layers: the render
/// server drives them, so the app process stays idle while they play.

struct LayerSpinner: NSViewRepresentable {
    var tint: Color
    var lineWidth: CGFloat

    func makeNSView(context: Context) -> SpinnerLayerView { SpinnerLayerView() }

    func updateNSView(_ view: SpinnerLayerView, context: Context) {
        view.configure(tint: NSColor(tint), lineWidth: lineWidth)
    }
}

final class SpinnerLayerView: NSView {
    private let track = CAShapeLayer()
    private let arc = CAShapeLayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        for l in [track, arc] {
            l.fillColor = nil
            l.lineCap = .round
            layer?.addSublayer(l)
        }
        arc.strokeEnd = 0.28
    }

    required init?(coder: NSCoder) { nil }

    func configure(tint: NSColor, lineWidth: CGFloat) {
        track.strokeColor = tint.withAlphaComponent(0.18).cgColor
        arc.strokeColor = tint.cgColor
        track.lineWidth = lineWidth
        arc.lineWidth = lineWidth
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let inset = arc.lineWidth / 2
        let path = CGPath(ellipseIn: bounds.insetBy(dx: inset, dy: inset), transform: nil)
        for l in [track, arc] {
            l.frame = bounds
            l.path = path
        }
        CATransaction.commit()
        if arc.animation(forKey: "spin") == nil {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -2 * Double.pi
            spin.duration = 1
            spin.repeatCount = .infinity
            spin.isRemovedOnCompletion = false
            arc.add(spin, forKey: "spin")
        }
    }
}

struct LayerBars: NSViewRepresentable {
    var playing: Bool
    var tint: Color
    var bars: Int

    func makeNSView(context: Context) -> BarsLayerView { BarsLayerView(count: bars) }

    func updateNSView(_ view: BarsLayerView, context: Context) {
        view.update(playing: playing, tint: NSColor(tint))
    }
}

final class BarsLayerView: NSView {
    private var bars: [CALayer] = []
    private var playing = false
    private static let durations: [Double] = [0.42, 0.31, 0.53, 0.37, 0.47, 0.34]
    private static let peaks: [CGFloat] = [0.85, 1.0, 0.7, 0.95, 0.75, 0.9]

    init(count: Int) {
        super.init(frame: .zero)
        wantsLayer = true
        bars = (0..<count).map { _ in
            let l = CALayer()
            layer?.addSublayer(l)
            return l
        }
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let w: CGFloat = 2.6, gap: CGFloat = 2
        let total = CGFloat(bars.count) * w + CGFloat(bars.count - 1) * gap
        let x0 = (bounds.width - total) / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, l) in bars.enumerated() {
            l.bounds = CGRect(x: 0, y: 0, width: w, height: bounds.height)
            l.position = CGPoint(x: x0 + CGFloat(i) * (w + gap) + w / 2, y: bounds.midY)
            l.cornerRadius = w / 2
        }
        CATransaction.commit()
        apply()
    }

    func update(playing: Bool, tint: NSColor) {
        bars.forEach { $0.backgroundColor = tint.cgColor }
        guard playing != self.playing else { return }
        self.playing = playing
        apply()
    }

    private func apply() {
        let rest = 2.6 / max(1, bounds.height)  // a dot
        for (i, l) in bars.enumerated() {
            if playing {
                guard l.animation(forKey: "level") == nil else { continue }
                let a = CABasicAnimation(keyPath: "transform.scale.y")
                a.fromValue = 0.22
                a.toValue = Self.peaks[i % Self.peaks.count]
                a.duration = Self.durations[i % Self.durations.count]
                a.autoreverses = true
                a.repeatCount = .infinity
                a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                a.timeOffset = Double(i) * 0.13
                l.add(a, forKey: "level")
            } else {
                l.removeAnimation(forKey: "level")
                l.transform = CATransform3DMakeScale(1, rest, 1)
            }
        }
    }
}

/// Untinted behind-window blur that swallows whatever menu bar text sits under it,
/// leaving the bar's own colour intact. Uses the window server's backdrop layer (what
/// NSVisualEffectView is built on) without the material tint; if that class is ever
/// missing it renders nothing rather than a mismatched grey band.
struct MenuBarBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> BackdropBlurView { BackdropBlurView() }
    func updateNSView(_ view: BackdropBlurView, context: Context) {}
}

final class BackdropBlurView: NSView {
    init() {
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override func makeBackingLayer() -> CALayer {
        guard let backdropClass = NSClassFromString("CABackdropLayer") as? CALayer.Type,
            let filterClass = NSClassFromString("CAFilter") as? NSObject.Type,
            let blur = filterClass.perform(NSSelectorFromString("filterWithType:"), with: "gaussianBlur")?
                .takeUnretainedValue() as? NSObject
        else { return CALayer() }
        let layer = backdropClass.init()
        blur.setValue(9, forKey: "inputRadius")
        blur.setValue(true, forKey: "inputNormalizeEdges")
        layer.filters = [blur]
        layer.setValue(true, forKey: "windowServerAware")
        layer.setValue(0.5, forKey: "scale")
        return layer
    }
}
