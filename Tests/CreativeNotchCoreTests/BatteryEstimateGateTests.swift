import Foundation
import Testing
@testable import CreativeNotchCore

/// The gate between IOKit's estimate and anything a person reads.
///
/// Every test drives an injected clock. There is no sleeping here and
/// there must never be: the whole point of this type is that its
/// temporal rules are arithmetic.
///
/// The tests read the constants rather than restating them, so the two
/// measured values can be revised from a fresh measurement without
/// rewriting the suite.
struct BatteryEstimateGateTests {

    /// Past the settling window, so the window is not what is under test.
    private var settled: TimeInterval { BatteryEstimateGate.settlingWindow + 1 }

    // MARK: - The unknown sentinel

    /// An unknown reading returns to silence rather than holding the last
    /// trusted value.
    ///
    /// Keeping the old number on screen while IOKit says it is
    /// recalculating is precisely the stale-value dishonesty the panel's
    /// "Estimating…" row exists to avoid — and it is the tempting fix,
    /// because holding the last value looks smoother than a row that
    /// changes back to text.
    @Test func anUnknownReadingReturnsToSilenceRatherThanHoldingTheLastValue() {
        var gate = BatteryEstimateGate()

        #expect(gate.accept(estimateMinutes: nil, now: settled) == nil)

        _ = gate.accept(estimateMinutes: 120, now: settled + 5)
        #expect(gate.accept(estimateMinutes: 121, now: settled + 10) == 121)

        #expect(gate.accept(estimateMinutes: nil, now: settled + 15) == nil)
    }

    /// An unknown reading in the middle of an agreeing run resets it.
    /// IOKit returning "still calculating" is a statement that the
    /// previous number no longer stands, so treating the readings either
    /// side of it as consecutive would agree across a gap the system
    /// itself flagged.
    @Test func anUnknownReadingBreaksTheAgreementRun() {
        var gate = BatteryEstimateGate()

        _ = gate.accept(estimateMinutes: 120, now: settled)
        _ = gate.accept(estimateMinutes: nil, now: settled + 5)

        #expect(gate.accept(estimateMinutes: 120, now: settled + 10) == nil)
    }

    // MARK: - Agreement

    /// The headline case: one reading is never enough.
    @Test func aSingleReadingIsNotTrusted() {
        var gate = BatteryEstimateGate()

        #expect(gate.accept(estimateMinutes: 120, now: settled) == nil)
    }

    @Test func twoAgreeingReadingsAreTrusted() {
        var gate = BatteryEstimateGate()

        _ = gate.accept(estimateMinutes: 120, now: settled)

        #expect(gate.accept(estimateMinutes: 121, now: settled + 5) == 121)
    }

    /// The roadmap's own example: 1:20 to 4:55 is not an estimate
    /// improving, it is an estimator that does not know yet.
    @Test func theRoadmapsSwingIsRejected() {
        var gate = BatteryEstimateGate()

        _ = gate.accept(estimateMinutes: 80, now: settled)

        #expect(gate.accept(estimateMinutes: 295, now: settled + 5) == nil)
    }

    /// Tolerance is proportional, so the same absolute disagreement is
    /// noise on a long estimate and a rejection on a short one. The short
    /// end is the end that matters — it is where a wrong number changes
    /// what someone does in the next five minutes.
    @Test func toleranceIsRelativeNotAbsolute() {
        var wide = BatteryEstimateGate()
        _ = wide.accept(estimateMinutes: 600, now: settled)
        #expect(wide.accept(estimateMinutes: 610, now: settled + 5) == 610)

        var narrow = BatteryEstimateGate()
        _ = narrow.accept(estimateMinutes: 10, now: settled)
        #expect(narrow.accept(estimateMinutes: 20, now: settled + 5) == nil)
    }

    /// A rejected reading is not discarded — it becomes the new candidate.
    /// Otherwise an estimator that has genuinely moved to a new value can
    /// never be believed again, because every future reading is compared
    /// against a number the system abandoned.
    @Test func aRejectedReadingBecomesTheNextCandidate() {
        var gate = BatteryEstimateGate()

        _ = gate.accept(estimateMinutes: 80, now: settled)
        #expect(gate.accept(estimateMinutes: 295, now: settled + 5) == nil)

        #expect(gate.accept(estimateMinutes: 297, now: settled + 10) == 297)
    }

    // MARK: - The settling window

    @Test func nothingIsShownInsideTheSettlingWindow() {
        var gate = BatteryEstimateGate()
        gate.noteTransition(at: 1000)

        _ = gate.accept(estimateMinutes: 120, now: 1000)

        #expect(gate.accept(estimateMinutes: 120, now: 1001) == nil)
    }

    /// Two identical readings inside the window are still not enough. The
    /// window is not a tie-breaker for weak evidence; it is a statement
    /// that the estimator has not recalibrated yet, and a stable wrong
    /// number is exactly what it produces while it settles.
    @Test func evenPerfectAgreementIsSuppressedInsideTheWindow() {
        var gate = BatteryEstimateGate()
        gate.noteTransition(at: 1000)

        _ = gate.accept(estimateMinutes: 120, now: 1001)
        _ = gate.accept(estimateMinutes: 120, now: 1002)

        #expect(gate.accept(estimateMinutes: 120, now: 1003) == nil)
    }

    @Test func agreementIsTrustedOnceTheWindowHasPassed() {
        var gate = BatteryEstimateGate()
        gate.noteTransition(at: 1000)
        let after = 1000 + BatteryEstimateGate.settlingWindow + 1

        _ = gate.accept(estimateMinutes: 120, now: after)

        #expect(gate.accept(estimateMinutes: 120, now: after + 5) == 120)
    }

    /// A second transition restarts the window. Plugging in, thinking
    /// better of it, and unplugging five seconds later must not leave the
    /// gate counting from the first of the two.
    @Test func aSecondTransitionRestartsTheWindow() {
        var gate = BatteryEstimateGate()
        gate.noteTransition(at: 1000)
        let afterFirst = 1000 + BatteryEstimateGate.settlingWindow + 1

        gate.noteTransition(at: afterFirst)

        _ = gate.accept(estimateMinutes: 120, now: afterFirst + 1)
        #expect(gate.accept(estimateMinutes: 120, now: afterFirst + 2) == nil)
    }

    /// A transition also invalidates the run collected before it. The
    /// machine is now doing something different, so agreement reached
    /// about the old regime says nothing about the new one.
    @Test func aTransitionDiscardsTheEarlierCandidate() {
        var gate = BatteryEstimateGate()
        _ = gate.accept(estimateMinutes: 120, now: settled)

        gate.noteTransition(at: settled + 1)
        let after = settled + 1 + BatteryEstimateGate.settlingWindow + 1

        #expect(gate.accept(estimateMinutes: 120, now: after) == nil)
    }

    // MARK: - Clock sanity

    /// Negative elapsed time is nonsense rather than an eternity. The
    /// failure mode of reading it as "long ago" is a gate that trusts an
    /// estimate the instant the charger moves, which is the one moment it
    /// must not.
    @Test func aBackwardClockDoesNotOpenTheGate() {
        var gate = BatteryEstimateGate()
        gate.noteTransition(at: 1000)

        _ = gate.accept(estimateMinutes: 120, now: 900)

        #expect(gate.accept(estimateMinutes: 120, now: 901) == nil)
    }
}
