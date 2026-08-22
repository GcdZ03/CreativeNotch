import AppKit
import SwiftUI

/// Passes clicks through everywhere except the currently-visible shape.
///
/// Without this the panel is a 620x260 transparent rectangle that swallows
/// every menu bar click behind it.
final class HitTestingHostingView<Content: View>: NSHostingView<Content> {

    /// Panel-local, bottom-left origin. Supplied by the controller so this
    /// view holds no geometry logic of its own.
    var visibleRectProvider: () -> CGRect = { .zero }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard visibleRectProvider().contains(local) else { return nil }
        return super.hitTest(point)
    }
}
