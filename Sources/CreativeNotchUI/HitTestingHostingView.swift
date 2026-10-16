import AppKit
import SwiftUI

/// Passes clicks through everywhere except the currently-visible shape.
///
/// Without this the panel is a 620x260 transparent rectangle that swallows
/// every menu bar click behind it.
public final class HitTestingHostingView<Content: View>: NSHostingView<Content> {

    /// Panel-local, bottom-left origin. Supplied by the controller so this
    /// view holds no geometry logic of its own.
    public var visibleRectProvider: () -> CGRect = { .zero }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        // `point` arrives in superview coordinates. Convert to *window base*
        // coordinates — bottom-left origin, y up — which is the space
        // NotchShape.visibleRect returns. Converting into this view's own
        // space would be wrong: NSHostingView is flipped, which inverts y.
        let inPanel = superview?.convert(point, to: nil) ?? point
        guard visibleRectProvider().contains(inPanel) else { return nil }
        return super.hitTest(point)
    }

    /// Two-finger swipes on the notch (spec 2026-10-17). Offered to the
    /// delegate first; whatever it does not take goes on as an ordinary
    /// scroll, so a list in the open panel still scrolls.
    ///
    /// No global monitor: these are scroll events AppKit already delivers
    /// to this view, because the cursor is over the drawn shape — the hit
    /// test above is what decides that.
    public var onScroll: (NSEvent) -> Bool = { _ in false }

    public override func scrollWheel(with event: NSEvent) {
        if !onScroll(event) { super.scrollWheel(with: event) }
    }
}
