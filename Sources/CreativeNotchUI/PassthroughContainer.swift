import AppKit

/// The panel's content view: claims a click only if one of its subviews
/// does.
///
/// `NSView.hitTest(_:)` returns `self` for any in-bounds point when no
/// subview claims it. That default is wrong here. The panel is a permanent
/// 620x260 window pinned under the menu bar, so a plain `NSView` content
/// view captured every click in that rect — including the menu bar either
/// side of the notch — while `HitTestingHostingView` and `HoverTracker`
/// were both correctly declining them. Each piece was right; the assembly
/// swallowed clicks anyway.
///
/// AppKit asks the content view first, so this is the layer that decides.
/// It is also what bounds a drop target, since dragging destinations are
/// found by hit-testing too.
final class PassthroughContainer: NSView {

    /// `point` arrives in this view's own coordinate space, which is what
    /// `subview.hitTest(_:)` expects for a direct child — so it is passed
    /// through unconverted.
    ///
    /// Front-to-back, matching AppKit's own order. No test fails without
    /// the reversal: `HoverTracker` declines every point, so no two
    /// subviews can currently claim the same one. It is kept because the
    /// order will start to matter the moment a module adds a second view
    /// that does claim points.
    override func hitTest(_ point: NSPoint) -> NSView? {
        for subview in subviews.reversed() {
            if let hit = subview.hitTest(point) { return hit }
        }
        return nil
    }
}
