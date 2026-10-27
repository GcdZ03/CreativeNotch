import Foundation

/// Says when a morph of the drawn shape is over (2026-10-28). `AppDelegate`
/// decides when the shape morphs (`PanelMove.morph`) and `NotchRootView` draws
/// it; this only waits out its time, so the accepted region can take the new
/// shape whole once it is drawn whole.
///
/// A seam so the wiring is testable without a clock: a test hands in a fake
/// that holds each completion until it says so, and a delegate a test builds
/// gets `InstantPanelMorpher`, so no suite has to await a morph.
@MainActor
protocol PanelMorpher {
    /// Calls `done` once `duration` has passed. Asked again before then, the
    /// first `done` is still called in its time; the app tells the two apart.
    func morph(over duration: Double, then done: @escaping @MainActor () -> Void)
}

/// No wait: `done` is called before returning. What every delegate starts
/// with; only the real launch swaps in `AnimatedPanelMorpher`.
struct InstantPanelMorpher: PanelMorpher {
    func morph(over duration: Double, then done: @escaping @MainActor () -> Void) {
        done()
    }
}

/// The real wait: one block on the main queue, `duration` from now.
///
/// One-shot, and only when the anchor changes on its display. Nothing to
/// cancel: a morph cut short leaves its block to find that it is no longer
/// the morph under way, which costs one comparison.
struct AnimatedPanelMorpher: PanelMorpher {
    func morph(over duration: Double, then done: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            MainActor.assumeIsolated { done() }
        }
    }
}
