import Foundation
import Testing
@testable import CreativeNotchCore

/// Spec section 5.3: 0.75s while active, backing off to 3s after two
/// minutes with no change, with a 2s floor under Low Power Mode.
///
/// This is the entire justification for admitting a timer into a project
/// whose stated rule is that it does not poll, so every number in it is
/// pinned rather than assumed.
struct ClipboardPollScheduleTests {

    @Test func theIntervalsAreWhatTheSpecSays() {
        #expect(ClipboardPollSchedule.activeInterval == 0.75)
        #expect(ClipboardPollSchedule.idleInterval == 3.0)
        #expect(ClipboardPollSchedule.idleAfter == 120)
        #expect(ClipboardPollSchedule.lowPowerFloor == 2.0)
    }

    @Test func aRecentChangePollsFast() {
        #expect(ClipboardPollSchedule.interval(sinceLastChange: 0, lowPower: false) == 0.75)
        #expect(ClipboardPollSchedule.interval(sinceLastChange: 30, lowPower: false) == 0.75)
    }

    @Test func twoQuietMinutesBacksOff() {
        #expect(ClipboardPollSchedule.interval(sinceLastChange: 200, lowPower: false) == 3.0)
    }

    /// Exactly at the threshold the back-off applies; a moment before it
    /// does not. Without this pair, `>` and `>=` are indistinguishable.
    @Test func theBackOffBoundaryIsInclusive() {
        let at = ClipboardPollSchedule.idleAfter
        #expect(ClipboardPollSchedule.interval(sinceLastChange: at, lowPower: false) == 3.0)
        #expect(ClipboardPollSchedule.interval(sinceLastChange: at - 0.001, lowPower: false) == 0.75)
    }

    /// The back-off is a function of elapsed time, so "resets on any
    /// change" is expressed by the caller passing a smaller elapsed value
    /// rather than by any state held here. This is the test that says so.
    @Test func aChangeResetsTheBackOff() {
        #expect(ClipboardPollSchedule.interval(sinceLastChange: 500, lowPower: false) == 3.0)
        #expect(ClipboardPollSchedule.interval(sinceLastChange: 0, lowPower: false) == 0.75)
    }

    /// Low Power raises the *floor*. It does not set the interval, which
    /// is why the already-slower idle rate is left alone rather than being
    /// pulled down to 2s.
    @Test func lowPowerRaisesTheActiveRateToTheFloor() {
        #expect(ClipboardPollSchedule.interval(sinceLastChange: 0, lowPower: true) == 2.0)
    }

    @Test func lowPowerDoesNotSpeedUpTheIdleRate() {
        #expect(ClipboardPollSchedule.interval(sinceLastChange: 200, lowPower: true) == 3.0)
    }

    /// Under Low Power the interval never drops below the floor, whatever
    /// the elapsed time.
    @Test func theFloorHoldsAcrossTheWholeRange() {
        for elapsed in stride(from: 0.0, through: 300.0, by: 7.5) {
            let interval = ClipboardPollSchedule.interval(sinceLastChange: elapsed, lowPower: true)
            #expect(interval >= ClipboardPollSchedule.lowPowerFloor)
        }
    }

    /// The interval is never faster than the active rate and never slower
    /// than the idle rate, whatever the inputs — including nonsense ones.
    @Test func theIntervalIsAlwaysWithinBounds() {
        for elapsed in stride(from: -50.0, through: 500.0, by: 12.5) {
            for lowPower in [true, false] {
                let interval = ClipboardPollSchedule.interval(
                    sinceLastChange: elapsed,
                    lowPower: lowPower
                )
                #expect(interval >= ClipboardPollSchedule.activeInterval)
                #expect(interval <= ClipboardPollSchedule.idleInterval)
            }
        }
    }

    /// Clocks are not guaranteed monotonic across sources. A negative
    /// elapsed time is nonsense, and nonsense must mean "poll at the
    /// normal rate", never "back off forever".
    @Test func aNegativeElapsedTimePollsAtTheActiveRate() {
        #expect(ClipboardPollSchedule.interval(sinceLastChange: -10, lowPower: false) == 0.75)
    }
}
