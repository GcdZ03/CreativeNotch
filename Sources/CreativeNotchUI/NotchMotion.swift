import SwiftUI

/// How the notch moves between states (spec 2026-10-15).
///
/// One spring for every change made opening feel stiff and closing feel
/// slow at once. Growing now uses a slightly bouncy spring and shrinking a
/// quicker, critically-damped one, so the panel arrives with a little life
/// and gets out of the way when dismissed.
enum NotchMotion {

    /// The opening spring's response, in seconds. `AppDelegate`'s growth lag
    /// is derived from it: the accepted region must not grow before the
    /// drawn shape has.
    static let openResponse: Double = 0.42

    static let open = Animation.spring(response: openResponse, dampingFraction: 0.74)
    static let close = Animation.spring(response: 0.26, dampingFraction: 1.0)

    /// The hover reaction is small, so it can afford to be quick.
    static let hover = Animation.spring(response: 0.22, dampingFraction: 0.7)

    /// Reduce Motion's stand-in for both springs: one short ease, no
    /// bounce, the same either way (spec 2026-10-17).
    static let reduced = Animation.easeInOut(duration: 0.2)

    static func animation(growing: Bool, reduceMotion: Bool = false) -> Animation {
        if reduceMotion { return reduced }
        return growing ? open : close
    }

    /// How long, at most, the spring a state change starts carries the
    /// shape, in seconds (2026-10-28, review of #81). The opening spring
    /// settles to within 0.1% in 0.85s, the closing one in 0.40s, Reduce
    /// Motion's ease in 0.2s. An anchor change inside it cannot say where
    /// the shape is drawn, so it does not morph (`AppDelegate.isSpringing`).
    static let springCarries: Double = 0.9

    /// Whether the now-playing cover slides between states. Under Reduce
    /// Motion it cross-fades instead: a cover travelling across the top of
    /// the screen is exactly the kind of motion the setting asks to avoid.
    static func slidesCover(reduceMotion: Bool) -> Bool { !reduceMotion }

    /// How much the closed notch's *drawing* grows while the cursor is over
    /// it, before the dwell decides whether to peek: split evenly either
    /// side, and downward only, since the top is the screen edge.
    static let hoverGrowth = CGSize(width: 6, height: 3)

    /// State content arrives softly once the shape starts to grow, and
    /// leaves fast so a collapsing shape never carries it.
    @MainActor static func content(reduceMotion: Bool = false) -> AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: AnyTransition(.blurReplace),
            removal: AnyTransition.opacity.animation(.easeOut(duration: 0.1))
        )
    }
}

extension View {
    /// Ties a cover to the one that slides between the closed badge, the
    /// music peek and the panel. A no-op without a namespace, so a view
    /// built on its own — in a test, or a preview — needs none.
    @ViewBuilder
    func nowPlayingCover(in namespace: Namespace.ID?) -> some View {
        if let namespace {
            matchedGeometryEffect(id: "nowPlayingCover", in: namespace)
        } else {
            self
        }
    }
}

/// Numbers that roll to their next value rather than snapping, the way
/// Apple's Live Activity guidance asks for counts that tick (spec
/// 2026-10-17). A fade under Reduce Motion.
///
/// The animation is scoped to `value`, so it runs only when the number
/// itself changes — never on a clock of its own.
struct RollingDigits<Value: Equatable>: ViewModifier {
    let value: Value
    let countsDown: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func transition(countsDown: Bool, reduceMotion: Bool) -> ContentTransition {
        reduceMotion ? .opacity : .numericText(countsDown: countsDown)
    }

    func body(content: Content) -> some View {
        content
            .contentTransition(Self.transition(countsDown: countsDown, reduceMotion: reduceMotion))
            .animation(reduceMotion ? .easeInOut(duration: 0.15) : .snappy(duration: 0.3), value: value)
    }
}

extension View {
    func rollingDigits<Value: Equatable>(_ value: Value, countsDown: Bool = false) -> some View {
        modifier(RollingDigits(value: value, countsDown: countsDown))
    }
}
