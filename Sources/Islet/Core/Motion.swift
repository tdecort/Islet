import AppKit
import SwiftUI

/// Every curve the island uses. Width and height run on separate springs so the
/// shape stretches like liquid instead of scaling like a rectangle: when opening,
/// the width leads and the height follows with a touch more overshoot; when
/// closing, the height retracts first and the width settles last.
enum Motion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private static let fade = Animation.easeInOut(duration: 0.22)

    static var openWidth: Animation { reduced ? fade : .spring(response: 0.40, dampingFraction: 0.74) }
    static var openHeight: Animation { reduced ? fade : .spring(response: 0.47, dampingFraction: 0.72) }
    static var closeWidth: Animation { reduced ? fade : .spring(response: 0.44, dampingFraction: 0.84) }
    static var closeHeight: Animation { reduced ? fade : .spring(response: 0.34, dampingFraction: 0.90) }

    /// Content swaps inside the island.
    static var content: Animation { reduced ? fade : .spring(response: 0.36, dampingFraction: 0.86) }
    static var contentIn: Animation { reduced ? fade : .spring(response: 0.36, dampingFraction: 0.86).delay(0.07) }
    static var contentOut: Animation { reduced ? fade : .easeOut(duration: 0.14) }

    /// Hover lift on a live activity.
    static var lift: Animation { reduced ? fade : .spring(response: 0.30, dampingFraction: 0.66) }

    /// The empty-island "boop": a quick swell, then a jelly settle.
    static var bumpOut: Animation { reduced ? fade : .spring(response: 0.20, dampingFraction: 0.58) }
    static var bumpBack: Animation { reduced ? fade : .spring(response: 0.50, dampingFraction: 0.46) }

    static var press: Animation { .spring(response: 0.24, dampingFraction: 0.62) }

    static func hudBar(_ speed: String) -> Animation? {
        switch speed {
        case "instant": return nil
        case "fast": return .spring(response: 0.16, dampingFraction: 0.9)
        default: return .spring(response: 0.32, dampingFraction: 0.82)
        }
    }

    static func haptic(_ pattern: NSHapticFeedbackManager.FeedbackPattern = .alignment) {
        guard Prefs.bool(Prefs.haptics) else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}

/// Apple's content transition for the island: material blur + slight shrink toward the
/// notch + fade. Insertions wait a beat so the shape leads and the content follows.
private struct IslandBlur: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        content
            .blur(radius: active ? 9 : 0)
            .scaleEffect(active ? 0.82 : 1, anchor: .top)
            .opacity(active ? 0 : 1)
    }
}

private struct PageSlide: ViewModifier {
    let offset: CGFloat
    func body(content: Content) -> some View {
        content
            .blur(radius: offset == 0 ? 0 : 6)
            .offset(x: offset)
            .opacity(offset == 0 ? 1 : 0)
    }
}

extension AnyTransition {
    static var island: AnyTransition {
        if Motion.reduced { return .opacity }
        return .asymmetric(
            insertion: .modifier(active: IslandBlur(active: true), identity: IslandBlur(active: false)).animation(Motion.contentIn),
            removal: .modifier(active: IslandBlur(active: true), identity: IslandBlur(active: false)).animation(Motion.contentOut)
        )
    }

    static func page(forward: Bool) -> AnyTransition {
        if Motion.reduced { return .opacity }
        let d: CGFloat = forward ? 28 : -28
        return .asymmetric(
            insertion: .modifier(active: PageSlide(offset: d), identity: PageSlide(offset: 0)),
            removal: .modifier(active: PageSlide(offset: -d), identity: PageSlide(offset: 0))
        )
    }

    static var bubble: AnyTransition {
        if Motion.reduced { return .opacity }
        return .modifier(active: IslandBlur(active: true), identity: IslandBlur(active: false))
            .combined(with: .scale(scale: 0.2, anchor: .leading))
    }
}
