import Foundation
import Testing
@testable import CreativeNotchCore

/// Hysteresis for the two low-battery thresholds.
struct LowBatteryArmingTests {

    @Test func theThresholdsAreTheOnesMacOSWarnsAt() {
        #expect(LowBatteryArming.thresholds == [20, 10])
    }

    // MARK: - Firing

    @Test func crossingTwentyFires() {
        var arming = LowBatteryArming()

        #expect(arming.crossing(level: 25, isPluggedIn: false) == nil)
        #expect(arming.crossing(level: 20, isPluggedIn: false) == 20)
    }

    @Test func crossingTenFiresAfterTwenty() {
        var arming = LowBatteryArming()

        _ = arming.crossing(level: 20, isPluggedIn: false)

        #expect(arming.crossing(level: 15, isPluggedIn: false) == nil)
        #expect(arming.crossing(level: 10, isPluggedIn: false) == 10)
    }

    // MARK: - Hysteresis, which is the whole point

    /// The headline case. IOKit reports whole percent over a continuous
    /// charge, so a battery sitting near a threshold jitters across it.
    /// Without this the notch would fire the same warning indefinitely.
    @Test func aThresholdSpeaksOncePerDischarge() {
        var arming = LowBatteryArming()

        #expect(arming.crossing(level: 20, isPluggedIn: false) == 20)
        #expect(arming.crossing(level: 19, isPluggedIn: false) == nil)
        #expect(arming.crossing(level: 20, isPluggedIn: false) == nil)
        #expect(arming.crossing(level: 18, isPluggedIn: false) == nil)
    }

    /// Re-arming needs the level back *above* the threshold, not merely
    /// the charger attached. Plugging in at 12% and pulling the cable
    /// again at 14% has not resolved anything the 20% warning was about.
    @Test func chargingAloneDoesNotRearm() {
        var arming = LowBatteryArming()
        _ = arming.crossing(level: 20, isPluggedIn: false)

        _ = arming.crossing(level: 12, isPluggedIn: true)
        _ = arming.crossing(level: 14, isPluggedIn: true)

        #expect(arming.crossing(level: 14, isPluggedIn: false) == nil)
    }

    @Test func chargingBackAboveTheThresholdRearmsIt() {
        var arming = LowBatteryArming()
        _ = arming.crossing(level: 20, isPluggedIn: false)

        _ = arming.crossing(level: 30, isPluggedIn: true)

        #expect(arming.crossing(level: 20, isPluggedIn: false) == 20)
    }

    /// Each threshold re-arms on its own terms. Climbing back to 15%
    /// resolves the 10% warning and not the 20% one.
    @Test func thresholdsRearmIndependently() {
        var arming = LowBatteryArming()
        _ = arming.crossing(level: 20, isPluggedIn: false)
        _ = arming.crossing(level: 10, isPluggedIn: false)

        _ = arming.crossing(level: 15, isPluggedIn: true)

        #expect(arming.crossing(level: 10, isPluggedIn: false) == 10)
        #expect(arming.crossing(level: 9, isPluggedIn: false) == nil)
    }

    // MARK: - Both at once

    /// A machine that slept at 25% and woke at 8% crossed both thresholds
    /// between two samples. Firing both would show the 20% warning and
    /// replace it with the 10% one in the same breath.
    @Test func aJumpPastBothSpeaksOnlyForTheMostUrgent() {
        var arming = LowBatteryArming()

        #expect(arming.crossing(level: 8, isPluggedIn: false) == 10)
    }

    @Test func aJumpPastBothDisarmsBoth() {
        var arming = LowBatteryArming()
        _ = arming.crossing(level: 8, isPluggedIn: false)

        // Staying below both, so neither re-arms and neither may speak
        // again. Continuing to drain is not new information.
        #expect(arming.crossing(level: 7, isPluggedIn: false) == nil)
        #expect(arming.crossing(level: 6, isPluggedIn: false) == nil)
    }

    /// Recovering above a threshold re-arms it even without the charger.
    ///
    /// This looks like a contradiction of `chargingAloneDoesNotRearm` and
    /// is the opposite case: there the *level* never recovered, only the
    /// cable changed. Here the level genuinely climbed back above 10%,
    /// which is what resolves the warning — and it does happen while
    /// discharging, because IOKit recalibrates and reports whole percent
    /// over a continuous charge.
    ///
    /// Found by a test that meant to assert the opposite. The first draft
    /// of `aJumpPastBothDisarmsBoth` stepped through 15% on its way from
    /// 8% to 7% and expected silence; the 10% threshold had legitimately
    /// re-armed in between.
    @Test func recoveringAboveAThresholdRearmsItWhileDischarging() {
        var arming = LowBatteryArming()
        _ = arming.crossing(level: 8, isPluggedIn: false)

        _ = arming.crossing(level: 15, isPluggedIn: false)

        #expect(arming.crossing(level: 7, isPluggedIn: false) == 10)
    }

    // MARK: - Not while plugged in

    /// A discharging machine is the only one with a problem. Passing 20%
    /// on the way *up* is good news and does not warrant interrupting.
    @Test func nothingFiresWhilePluggedIn() {
        var arming = LowBatteryArming()

        #expect(arming.crossing(level: 5, isPluggedIn: true) == nil)
    }
}
