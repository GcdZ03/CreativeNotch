import Foundation
import Testing
@testable import CreativeNotchCore

struct TimerStepperTests {

    @Test func belowTenItMovesOneMinuteAtATime() {
        #expect(TimerStepper.increment(3) == 4)
        #expect(TimerStepper.decrement(3) == 2)
    }

    @Test func fromTenUpItMovesFiveAtATime() {
        #expect(TimerStepper.increment(10) == 15)
        #expect(TimerStepper.increment(45) == 50)
        #expect(TimerStepper.decrement(45) == 40)
    }

    /// The threshold is the only interesting part. Stepping must be
    /// reversible across it: whatever a click up does, a click down undoes.
    /// A single `>= 10` rule strands 10 — up 5, down 5 — and 9 becomes
    /// unreachable once you have left it.
    @Test func steppingIsReversibleAcrossTheThreshold() {
        #expect(TimerStepper.increment(9) == 10)
        #expect(TimerStepper.decrement(10) == 9)
    }

    /// Reversible everywhere the step is not clamped.
    ///
    /// The exception is real and deliberately not papered over: 99 is the
    /// cap and is not a multiple of five above the threshold, so stepping up
    /// from 95-98 lands on 99 and stepping back lands on 94. Asserting
    /// universal reversibility would be asserting something false — the
    /// clamped range gets its own test below instead.
    @Test func everyUnclampedValueReturnsToItselfSteppingUpThenDown() {
        for minutes in TimerStepper.minimum..<TimerStepper.maximum {
            let up = TimerStepper.increment(minutes)
            guard up < TimerStepper.maximum else { continue }
            #expect(TimerStepper.decrement(up) == minutes,
                    "\(minutes) -> \(up) -> \(TimerStepper.decrement(up))")
        }
    }

    /// What the clamp actually does, pinned rather than left to be
    /// discovered. Stepping up from just below the cap lands on it, and
    /// stepping back lands on the nearest step below — not where you
    /// started.
    @Test func steppingPastTheCapLandsOnItAndDoesNotReturn() {
        #expect(TimerStepper.increment(97) == 99)
        #expect(TimerStepper.decrement(99) == 94)
    }

    @Test func itStopsAtTheFloorRatherThanGoingBelowIt() {
        #expect(TimerStepper.decrement(1) == 1)
        #expect(TimerStepper.decrement(TimerStepper.minimum) == TimerStepper.minimum)
    }

    /// The cap is what keeps the badge three glyphs wide, so overshooting
    /// it would break the fixed-width ear, not merely allow a long timer.
    @Test func itStopsAtTheCapRatherThanOvershootingIt() {
        #expect(TimerStepper.increment(99) == 99)
        #expect(TimerStepper.increment(97) == 99)
        #expect(TimerStepper.maximum == 99)
    }

    /// Every reachable value must be a duration `Countdown` will accept —
    /// otherwise the Start button offers something the model rejects, and
    /// the click silently does nothing.
    @Test func everyReachableValueIsAValidCountdown() {
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
        var minutes = TimerStepper.minimum
        var seen: Set<Int> = []

        // Bounded, not `while !seen.contains(minutes)`. That form terminates
        // only because `increment` clamps — so a mutation removing the clamp
        // made this hang forever instead of failing, which in CI is a
        // timeout rather than a diagnosis. The bound is generous enough that
        // reaching it means the stepper is broken, and the assertion below
        // says so.
        for _ in 0...TimerStepper.maximum {
            guard !seen.contains(minutes) else { break }
            seen.insert(minutes)
            #expect(Countdown(duration: TimeInterval(minutes) * 60, startingAt: t0) != nil,
                    "\(minutes)m is reachable but not a valid Countdown")
            minutes = TimerStepper.increment(minutes)
        }

        // The walk converged and reached the top, rather than stalling early
        // or running away.
        #expect(seen.contains(TimerStepper.maximum))
        #expect(seen.allSatisfy { $0 <= TimerStepper.maximum })
    }

    /// The cap is derived from `Countdown.maxDuration`, not spelled twice.
    @Test func theCapFollowsTheModelRatherThanRepeatingIt() {
        #expect(TimeInterval(TimerStepper.maximum) * 60 == Countdown.maxDuration)
    }
}
