import Foundation
import Testing
@testable import CreativeNotchCore

/// The ambient light sensor micro-adjusts the backlight roughly 60 times a
/// second — 1729 events measured in one short session, none of them exact
/// duplicates, so `HUDCoalescer` cannot help. This gate is what stops the
/// notch strobing continuously for drift nobody asked to see.
///
/// `isSignificant` and `commitShown` are exercised directly (rather than
/// through a combined convenience) everywhere the split itself matters.
/// Where it doesn't, `acceptAndCommitIfSignificant` below stands in for
/// what a well-behaved caller does: query, then commit only what it
/// actually shows -- which, at this layer with nothing standing between
/// significance and display, is every significant result.
private extension HUDSignificanceGate {
    mutating func acceptAndCommitIfSignificant(_ kind: HUDKind) -> Bool {
        let significant = isSignificant(kind)
        if significant { commitShown(kind) }
        return significant
    }
}

struct HUDSignificanceGateTests {

    @Test func theFirstEventOfAKindIsAlwaysSignificant() {
        var gate = HUDSignificanceGate()
        let result = gate.acceptAndCommitIfSignificant(.volume(0.5))
        #expect(result)
    }

    @Test func ambientDriftIsNotSignificant() {
        // Real captured values: 0.44905930 -> 0.44898808, about 0.00007
        // apart — three orders of magnitude below the threshold.
        var gate = HUDSignificanceGate()
        _ = gate.acceptAndCommitIfSignificant(.brightness(0.44905930))
        let result = gate.acceptAndCommitIfSignificant(.brightness(0.44898808))
        #expect(result == false)
    }

    @Test func aKeyStepIsSignificant() {
        // The keys move the level in 1/16 steps, comfortably above the
        // 1/32 threshold.
        var gate = HUDSignificanceGate()
        _ = gate.acceptAndCommitIfSignificant(.volume(0))
        let result = gate.acceptAndCommitIfSignificant(.volume(0.0625))
        #expect(result)
    }

    @Test func aSlowDragAccumulatesUntilItCrossesTheThreshold() {
        // Each step alone is too small, but they must accumulate against
        // the last *shown* value, not the last observed one, or a slow
        // drag would never show at all.
        var gate = HUDSignificanceGate()
        let baseline = gate.acceptAndCommitIfSignificant(.volume(0))
        #expect(baseline)                                // baseline, shown
        let smallStep = gate.acceptAndCommitIfSignificant(.volume(0.02))
        #expect(smallStep == false)                      // too small alone
        let biggerStep = gate.acceptAndCommitIfSignificant(.volume(0.04))
        #expect(biggerStep)                               // 0.04 from the
                                                           // last *shown* 0,
                                                           // not from 0.02
    }

    @Test func comparingAgainstTheLastObservedValueWouldMissTheDrag() {
        // Same shape as above, but pins the exact behaviour: after the
        // 0.02 step is rejected, the baseline for the next comparison must
        // still be 0 (last shown), not 0.02 (last observed). If it were
        // 0.02, the next 0.02 step would only total 0.02 more and would
        // also be rejected.
        var gate = HUDSignificanceGate()
        _ = gate.acceptAndCommitIfSignificant(.volume(0))
        _ = gate.acceptAndCommitIfSignificant(.volume(0.02))    // rejected, does not move baseline
        let result = gate.acceptAndCommitIfSignificant(.volume(0.02 + 0.02))
        #expect(result)
    }

    /// Boolean, no magnitude — so the threshold does not apply, but
    /// "always show" was too strong. A driver re-notifying the same mute
    /// state popped a speaker HUD every time it did so.
    @Test func muteShowsOnlyWhenItActuallyChanges() {
        var gate = HUDSignificanceGate()
        let first = gate.acceptAndCommitIfSignificant(.mute(true))
        #expect(first)
        let repeated = gate.acceptAndCommitIfSignificant(.mute(true))
        #expect(!repeated, "the same state must not show twice")
        let flipped = gate.acceptAndCommitIfSignificant(.mute(false))
        #expect(flipped)
    }

    @Test func kindsAreTrackedIndependently() {
        var gate = HUDSignificanceGate()
        let volumeFirst = gate.acceptAndCommitIfSignificant(.volume(0.5))
        #expect(volumeFirst)
        // Brightness's first event is significant on its own, unaffected
        // by volume already having a baseline.
        let brightnessFirst = gate.acceptAndCommitIfSignificant(.brightness(0.5))
        #expect(brightnessFirst)
        // A brightness change must not reset volume's baseline.
        let volumeDrift = gate.acceptAndCommitIfSignificant(.volume(0.5 + 0.00007))
        #expect(volumeDrift == false)
    }

    @Test func theBoundaryIsInclusive() {
        // Values chosen so the arithmetic is exact: 1/32 is exactly
        // representable in binary floating point, and starting from 0
        // avoids the precision loss that defeated an earlier boundary test
        // on this module (100 + 0.05 evaluates to 100.04999999999971).
        var gate = HUDSignificanceGate()
        _ = gate.acceptAndCommitIfSignificant(.volume(0))
        let atThreshold = gate.acceptAndCommitIfSignificant(.volume(HUDSignificanceGate.threshold))
        #expect(atThreshold)
    }

    @Test func justUnderTheBoundaryIsNotSignificant() {
        var gate = HUDSignificanceGate()
        _ = gate.acceptAndCommitIfSignificant(.volume(0))
        // Half the threshold, exactly representable, clearly under.
        let result = gate.acceptAndCommitIfSignificant(.volume(HUDSignificanceGate.threshold / 2))
        #expect(result == false)
    }

    @Test func theThresholdIsWhatTheSpecSays() {
        #expect(HUDSignificanceGate.threshold == 0.03125)
    }

    // MARK: - The query/commit split

    /// `isSignificant` alone must never move the baseline. If it did, a
    /// value that is significant, then filtered out by something *outside*
    /// the gate (an attribution check, for instance) would still poison
    /// the baseline for the next real comparison -- exactly the phantom
    /// baseline bug this split exists to close.
    @Test func queryingSignificanceAloneDoesNotCommitTheBaseline() {
        var gate = HUDSignificanceGate()
        _ = gate.isSignificant(.volume(0.5))
        gate.commitShown(.volume(0.5))

        // Querying repeatedly, with no commit, must not move the baseline
        // off 0.5.
        _ = gate.isSignificant(.volume(0.5625))
        _ = gate.isSignificant(.volume(0.5625))
        #expect(gate.isSignificant(.volume(0.5625)))
    }

    /// Pins `commitShown` actually writing the baseline. If the assignment
    /// inside it were deleted, the baseline would stay at 0.5 forever, and
    /// 0.20007 would compare against 0.5 (a ~0.3 gap, significant) instead
    /// of the committed 0.2 (a 0.00007 gap, not significant).
    @Test func commitShownMovesTheBaselineToWhatWasActuallyShown() {
        var gate = HUDSignificanceGate()
        _ = gate.isSignificant(.brightness(0.5))
        gate.commitShown(.brightness(0.5))

        _ = gate.isSignificant(.brightness(0.2))
        gate.commitShown(.brightness(0.2))

        #expect(gate.isSignificant(.brightness(0.20007)) == false)
    }
}
