import AppKit
import CreativeNotchCore

/// One scroll event, reduced to what a swipe needs (spec 2026-10-17).
///
/// A value rather than the `NSEvent`, so `AppDelegate.handleScroll` can be
/// tested: AppKit offers no way to build a scroll event with phases.
struct ScrollSample: Equatable {
    enum Phase: Equatable { case began, changed, ended, cancelled, other }

    var phase: Phase
    var isMomentum: Bool
    /// Trackpads (and Magic Mice) report precise deltas; a notched wheel
    /// does not.
    var isPrecise: Bool
    /// In finger space: see `NotchSwipe.fingerDelta`.
    var finger: CGVector
}

extension ScrollSample {
    init(_ event: NSEvent) {
        let phase: Phase
        switch event.phase {
        case .began, .mayBegin: phase = .began
        case .changed: phase = .changed
        case .ended: phase = .ended
        case .cancelled: phase = .cancelled
        default: phase = .other
        }
        self.init(
            phase: phase,
            isMomentum: event.momentumPhase != [],
            isPrecise: event.hasPreciseScrollingDeltas,
            finger: NotchSwipe.fingerDelta(
                deltaX: event.scrollingDeltaX,
                deltaY: event.scrollingDeltaY,
                invertedFromDevice: event.isDirectionInvertedFromDevice
            )
        )
    }
}
