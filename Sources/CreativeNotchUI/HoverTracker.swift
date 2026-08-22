import AppKit

/// Hover detection via `NSTrackingArea` on the panel itself — never a global
/// mouse monitor, so it costs nothing when the cursor is elsewhere.
///
/// A 300ms dwell is required before peeking. The notch sits directly on the
/// path to the menu bar and the traffic lights, so a deliberate pause is
/// what separates intent from a cursor passing through.
public final class HoverTracker: NSView {

    public static let dwell: Duration = .milliseconds(300)

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

    public func updateTrackingRect(_ rect: CGRect) {
        trackingRect = rect
        updateTrackingAreas()
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
        onEnter()
        dwellTask?.cancel()
        dwellTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.dwell)
            guard !Task.isCancelled else { return }
            self?.onDwell()
        }
    }

    public override func mouseExited(with event: NSEvent) {
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
