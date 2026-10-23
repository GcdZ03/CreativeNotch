import AppKit
import CreativeNotchCore

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

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Registering here rather than at the call site keeps the drop
        // contract with the view that implements it.
        registerForDraggedTypes([.fileURL, .string, .png, .tiff])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("PassthroughContainer is not loaded from a nib") }

    // MARK: - Dragging destination

    var onDragEntered: () -> Void = {}
    var onDragExited: () -> Void = {}
    var onDrop: ([DropPayload]) -> Bool = { _ in false }

    /// Whether a drop would be taken at all — the shelf preference, read
    /// fresh on every drag. Answering `.copy` for a drop that will be
    /// refused shows a copy badge on the cursor for nothing.
    var acceptsDrops: () -> Bool = { true }

    /// Whether the drag currently over the view is one it took. The exit and
    /// the drop belong to the drag that entered: a drag declined on entry
    /// must not close the shelf on its way out.
    private(set) var isTrackingDrag = false

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        // `draggingSource` is non-nil exactly when the drag started in this
        // process — which here means an item dragged *out* of the shelf.
        dragEntered(fromThisApp: sender.draggingSource != nil)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        dragExited()
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard isTrackingDrag else { return false }
        isTrackingDrag = false
        return onDrop(sender.draggingPasteboard.dropPayloads())
    }

    /// The decision behind `draggingEntered`, taking the one fact it needs
    /// from `NSDraggingInfo` — which cannot be constructed outside AppKit's
    /// drag machinery — so a test can drive it.
    ///
    /// A drag from this app is declined. Dragging an item out of the open
    /// shelf crosses the panel on its way, and taking it turned the shelf
    /// into a drop target that stored the item a second time ("name 2")
    /// when let go over the panel.
    @discardableResult
    func dragEntered(fromThisApp: Bool) -> NSDragOperation {
        isTrackingDrag = !fromThisApp && acceptsDrops()
        guard isTrackingDrag else { return [] }
        onDragEntered()
        return .copy
    }

    /// Not gated on `acceptsDrops`: a drag taken while the shelf was on
    /// must still put the notch back if it was switched off mid-drag.
    func dragExited() {
        guard isTrackingDrag else { return }
        isTrackingDrag = false
        onDragExited()
    }

    /// `point` arrives in the *superview's* coordinate space, as for every
    /// `NSView.hitTest(_:)`, and a direct child's `hitTest(_:)` expects the
    /// same thing — its superview's space, which is this view's own. The
    /// two coincide because this is the content view of a borderless panel,
    /// filling the frame view from its origin, so the point is passed
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
