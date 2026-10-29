import AppKit

/// Hover detection via `NSTrackingArea` on the panel itself — never a global
/// mouse monitor, so it costs nothing when the cursor is elsewhere.
///
/// A 300ms dwell is required before peeking. The notch sits directly on the
/// path to the menu bar and the traffic lights, so a deliberate pause is
/// what separates intent from a cursor passing through.
public final class HoverTracker: NSView {

    public static let dwell: Duration = .milliseconds(300)

    /// How long to wait, asked afresh each time the pointer arrives, so a
    /// changed "open on hover" delay applies on the next hover without a
    /// re-sync (2026-10-17). Defaults to the peek's fixed dwell.
    public var dwellDuration: () -> Duration = { HoverTracker.dwell }

    func currentDwell() -> Duration { dwellDuration() }

    /// Fires the moment the cursor enters, before the dwell elapses.
    /// `onDwell` says "the user meant to open this"; `onEnter` says "the
    /// cursor is back", which is what cancels a pending dismissal.
    public var onEnter: () -> Void = {}
    public var onDwell: () -> Void = {}
    public var onExit: () -> Void = {}

    /// Readable so the funnel that keeps it in sync with the state can
    /// be verified; only `updateTrackingRect(_:)` may set it.
    public private(set) var trackingRect: CGRect = .zero
    /// Exposed for the same reason as `AppDelegate.growthTask`: tests
    /// await it rather than sleeping past it.
    private(set) var dwellTask: Task<Void, Never>?

    /// `NSTrackingArea` rects are interpreted in the owning view's own
    /// coordinate space. Staying unflipped (the `NSView` default) matches
    /// `NotchShape.visibleRect`'s documented bottom-left, y-up convention —
    /// unlike `NSHostingView`, which is flipped. Declared explicitly rather
    /// than left implicit, since this is exactly the seam that produced a
    /// y-axis inversion bug elsewhere in this codebase.
    public override var isFlipped: Bool { false }

    /// Whether the pointer is inside `trackingRect`, as far as this view
    /// knows: set by the enter and exit events, and re-read whenever the
    /// rect is replaced.
    private(set) var isPointerInside = false

    /// Where the pointer is, in this view's coordinates, or `nil` when that
    /// cannot be known (no window). Injected so a test can place it; `nil`
    /// means the real one, read once from the window — never polled.
    var pointerLocation: (() -> CGPoint?)?

    private func currentPointer() -> CGPoint? {
        if let pointerLocation { return pointerLocation() }
        guard let window else { return nil }
        return convert(window.mouseLocationOutsideOfEventStream, from: nil)
    }

    /// Replaces the tracking area, then re-reads where the pointer is.
    ///
    /// AppKit sends no `mouseExited` when an area is *replaced*, so a shape
    /// that shrank out from under a still pointer — a peek expiring, the
    /// panel closing from a button — left this view, and `isHovering`
    /// downstream, believing the pointer was still over it. Found outside
    /// the new rect after being inside, that is reported as the exit it is.
    ///
    /// No synthetic *enter* the other way: a region growing under the
    /// pointer is `AppDelegate.keepOpenIfPointerInside`'s case, and a dwell
    /// started by a rect change rather than by the user would peek unasked.
    /// **Nor a silent one.** Growth never sets `isPointerInside`: a pointer
    /// that only came to be inside because a peek grew around it was never
    /// reported as entering, so its later shrink must not be reported as an
    /// exit either -- `collapse()` would close a peek hover never opened.
    /// Only a real enter, or `acknowledgePointerInside()`, makes it inside.
    public func updateTrackingRect(_ rect: CGRect) {
        trackingRect = rect
        updateTrackingAreas()
        guard let pointer = currentPointer() else { return }
        let inside = rect.contains(pointer)
        let left = isPointerInside && !inside
        isPointerInside = isPointerInside && inside
        if left { exited() }
    }

    /// The app has found the pointer inside and is treating it as hovering
    /// (`AppDelegate.keepOpenIfPointerInside`), so a later shrink out from
    /// under it is an exit like any other. No `onEnter` and no dwell: the
    /// caller has already done what an enter would.
    func acknowledgePointerInside() {
        isPointerInside = true
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        guard !trackingRect.isEmpty else { return }
        addTrackingArea(NSTrackingArea(
            rect: trackingRect,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self
        ))
    }

    public override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
        onEnter()
        armDwell()
    }

    /// A two-finger swipe has started on the notch (2026-10-29): the dwell
    /// waits, so a peek -- or, with open on hover, the panel -- cannot open
    /// under the fingers and turn the rest of the swipe into something else.
    func holdDwell() {
        dwellTask?.cancel()
        dwellTask = nil
    }

    /// The swipe did nothing: start the dwell again, as if just arrived. Not
    /// called after a swipe that acted -- a peek opening the moment the
    /// fingers lift would be a second thing nobody asked for.
    func rearmDwell() {
        guard isPointerInside else { return }
        armDwell()
    }

    private func armDwell() {
        dwellTask?.cancel()
        dwellTask = Task { @MainActor [weak self] in
            guard let wait = self?.currentDwell() else { return }
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            self?.onDwell()
        }
    }

    public override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        exited()
    }

    private func exited() {
        dwellTask?.cancel()
        dwellTask = nil
        onExit()
    }

    /// This view sits *above* the hosting view so its tracking area covers
    /// the panel. Returning nil means it never intercepts a click, so taps
    /// still reach SwiftUI underneath. Tracking areas deliver
    /// `mouseEntered`/`mouseExited` regardless of hit-testing, so hover is
    /// unaffected.
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
