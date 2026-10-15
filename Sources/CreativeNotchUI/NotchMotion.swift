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

    static func animation(growing: Bool) -> Animation { growing ? open : close }

    /// How much the closed notch's *drawing* grows while the cursor is over
    /// it, before the dwell decides whether to peek: split evenly either
    /// side, and downward only, since the top is the screen edge.
    static let hoverGrowth = CGSize(width: 6, height: 3)

    /// State content arrives softly once the shape starts to grow, and
    /// leaves fast so a collapsing shape never carries it.
    @MainActor static var content: AnyTransition {
        .asymmetric(
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
