import Foundation
import Testing
@testable import CreativeNotchCore

/// The ambient light sensor micro-adjusts the backlight roughly 60 times a
/// second — 1729 events measured in one short session, none of them exact
/// duplicates, so `HUDCoalescer` cannot help. This gate is what stops the
/// notch strobing continuously for drift nobody asked to see.
struct HUDSignificanceGateTests {

    @Test func theFirstEventOfAKindIsAlwaysSignificant() {
        var gate = HUDSignificanceGate()
        let result = gate.accept(.volume(0.5))
        #expect(result)
    }

    @Test func ambientDriftIsNotSignificant() {
        // Real captured values: 0.44905930 -> 0.44898808, about 0.00007
        // apart — three orders of magnitude below the threshold.
        var gate = HUDSignificanceGate()
        _ = gate.accept(.brightness(0.44905930))
        let result = gate.accept(.brightness(0.44898808))
        #expect(result == false)
    }

    @Test func aKeyStepIsSignificant() {
        // The keys move the level in 1/16 steps, comfortably above the
        // 1/32 threshold.
        var gate = HUDSignificanceGate()
        _ = gate.accept(.volume(0))
        let result = gate.accept(.volume(0.0625))
        #expect(result)
    }

    @Test func aSlowDragAccumulatesUntilItCrossesTheThreshold() {
        // Each step alone is too small, but they must accumulate against
        // the last *shown* value, not the last observed one, or a slow
        // drag would never show at all.
        var gate = HUDSignificanceGate()
        let baseline = gate.accept(.volume(0))
        #expect(baseline)                                // baseline, shown
        let smallStep = gate.accept(.volume(0.02))
        #expect(smallStep == false)                      // too small alone
        let biggerStep = gate.accept(.volume(0.04))
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
        _ = gate.accept(.volume(0))
        _ = gate.accept(.volume(0.02))    // rejected, does not move baseline
        let result = gate.accept(.volume(0.02 + 0.02))
        #expect(result)
    }

    @Test func muteAlwaysShows() {
        // Boolean, no magnitude — the threshold comparison does not apply.
        var gate = HUDSignificanceGate()
        let first = gate.accept(.mute(true))
        #expect(first)
        let repeated = gate.accept(.mute(true))
        #expect(repeated)
        let flipped = gate.accept(.mute(false))
        #expect(flipped)
    }

    @Test func kindsAreTrackedIndependently() {
        var gate = HUDSignificanceGate()
        let volumeFirst = gate.accept(.volume(0.5))
        #expect(volumeFirst)
        // Brightness's first event is significant on its own, unaffected
        // by volume already having a baseline.
        let brightnessFirst = gate.accept(.brightness(0.5))
        #expect(brightnessFirst)
        // A brightness change must not reset volume's baseline.
        let volumeDrift = gate.accept(.volume(0.5 + 0.00007))
        #expect(volumeDrift == false)
    }

    @Test func theBoundaryIsInclusive() {
        // Values chosen so the arithmetic is exact: 1/32 is exactly
        // representable in binary floating point, and starting from 0
        // avoids the precision loss that defeated an earlier boundary test
        // on this module (100 + 0.05 evaluates to 100.04999999999971).
        var gate = HUDSignificanceGate()
        _ = gate.accept(.volume(0))
        let atThreshold = gate.accept(.volume(HUDSignificanceGate.threshold))
        #expect(atThreshold)
    }

    @Test func justUnderTheBoundaryIsNotSignificant() {
        var gate = HUDSignificanceGate()
        _ = gate.accept(.volume(0))
        // Half the threshold, exactly representable, clearly under.
        let result = gate.accept(.volume(HUDSignificanceGate.threshold / 2))
        #expect(result == false)
    }

    @Test func theThresholdIsWhatTheSpecSays() {
        #expect(HUDSignificanceGate.threshold == 0.03125)
    }
}
