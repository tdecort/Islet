import SwiftUI

/// The island silhouette. Attached mode hangs from the top edge with concave
/// "shoulders" that melt into the bezel, like the hardware notch. Detached mode
/// (screens without a notch) is a free-floating continuous rounded rectangle.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    var detached = false

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        if detached {
            let r = min(bottomRadius, rect.height / 2)
            return Path(roundedRect: rect, cornerRadius: r, style: .continuous)
        }
        let t = max(0, min(topRadius, rect.width / 4))
        let b = max(0, min(bottomRadius, (rect.width - 2 * t) / 2, rect.height - t))
        // 0.5523 makes a circular quadrant; a slightly longer handle reads as Apple's
        // smoother "continuous" corner.
        let k: CGFloat = 0.62
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        // left shoulder (concave)
        p.addCurve(
            to: CGPoint(x: rect.minX + t, y: rect.minY + t),
            control1: CGPoint(x: rect.minX + t * k, y: rect.minY),
            control2: CGPoint(x: rect.minX + t, y: rect.minY + t * (1 - k))
        )
        p.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        // bottom-left corner (convex)
        p.addCurve(
            to: CGPoint(x: rect.minX + t + b, y: rect.maxY),
            control1: CGPoint(x: rect.minX + t, y: rect.maxY - b * (1 - k)),
            control2: CGPoint(x: rect.minX + t + b * (1 - k), y: rect.maxY)
        )
        p.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        // bottom-right corner
        p.addCurve(
            to: CGPoint(x: rect.maxX - t, y: rect.maxY - b),
            control1: CGPoint(x: rect.maxX - t - b * (1 - k), y: rect.maxY),
            control2: CGPoint(x: rect.maxX - t, y: rect.maxY - b * (1 - k))
        )
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        // right shoulder
        p.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control1: CGPoint(x: rect.maxX - t, y: rect.minY + t * (1 - k)),
            control2: CGPoint(x: rect.maxX - t * k, y: rect.minY)
        )
        p.closeSubpath()
        return p
    }
}
