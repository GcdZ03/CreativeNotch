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
}
