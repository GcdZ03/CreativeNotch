import Foundation
import Testing
@testable import CreativeNotchCore

struct TimerDisplayTests {

    // MARK: text

    /// A 25-minute timer must read "25m" the instant it starts. `floor`
    /// would show "24m" immediately and read as broken.
    @Test func aFreshTimerShowsItsFullMinutes() {
        #expect(TimerDisplay.text(remaining: 1500) == "25m")
    }

    @Test func minutesRoundUpSoTheyOnlyDropOnTheBoundary() {
        #expect(TimerDisplay.text(remaining: 1441) == "25m")
        #expect(TimerDisplay.text(remaining: 1440) == "24m")
        #expect(TimerDisplay.text(remaining: 1439) == "24m")
    }

    @Test func theLastMinuteSwitchesToSeconds() {
        #expect(TimerDisplay.text(remaining: 60) == "1m")
        #expect(TimerDisplay.text(remaining: 59) == "0:59")
        #expect(TimerDisplay.text(remaining: 45) == "0:45")
    }

    @Test func secondsArePaddedSoTheWidthDoesNotJump() {
        #expect(TimerDisplay.text(remaining: 9) == "0:09")
        #expect(TimerDisplay.text(remaining: 5.4) == "0:06")
    }

    @Test func aFinishedTimerShowsZero() {
        #expect(TimerDisplay.text(remaining: 0) == "0:00")
        #expect(TimerDisplay.text(remaining: -30) == "0:00")
    }

    @Test func theMaximumDurationStillFitsTheFormat() {
        #expect(TimerDisplay.text(remaining: Countdown.maxDuration) == "99m")
    }

    // MARK: nextChange

    /// Above a minute the display changes on the minute, so nothing should
    /// be scheduled before then. This is the difference between 25 redraws
    /// and 1,500.
    @Test func aboveAMinuteTheNextChangeIsTheMinuteBoundary() throws {
        #expect(try #require(TimerDisplay.nextChange(remaining: 1500)) == 60)
        #expect(try #require(TimerDisplay.nextChange(remaining: 1441)) == 1)
    }

    /// The boundary that is easy to get wrong: at exactly 60s the text is
    /// "1m", and it changes one second later when seconds take over --
    /// not 60 seconds later.
    @Test func theHandoverFromMinutesToSecondsIsOneSecondAway() throws {
        #expect(try #require(TimerDisplay.nextChange(remaining: 60)) == 1)
    }

    @Test func belowAMinuteTheNextChangeIsTheNextSecond() throws {
        #expect(try #require(TimerDisplay.nextChange(remaining: 45)) == 1)
        #expect(abs(try #require(TimerDisplay.nextChange(remaining: 44.3)) - 0.3) < 0.001)
    }

    /// A finished timer has nothing left to schedule; returning a delay
    /// would keep waking the machine forever.
    @Test func aFinishedTimerSchedulesNothing() {
        #expect(TimerDisplay.nextChange(remaining: 0) == nil)
        #expect(TimerDisplay.nextChange(remaining: -5) == nil)
    }

    /// Whatever `nextChange` returns must actually land on a different
    /// string, at every scale. If this ever fails the schedule is either
    /// waking too early (wasted redraw) or too late (stale display).
    @Test func everyScheduledWakeLandsOnADifferentString() throws {
        for remaining in stride(from: 0.5, through: Countdown.maxDuration, by: 0.5) {
            let delay = try #require(TimerDisplay.nextChange(remaining: remaining))
            let before = TimerDisplay.text(remaining: remaining)
            let after = TimerDisplay.text(remaining: remaining - delay)
            #expect(before != after, "no change at \(remaining) after \(delay)")
            #expect(delay > 0, "non-positive delay at \(remaining)")
        }
    }

    @Test func theWidestTextIsAsWideAsAnythingTheFormatProduces() {
        for remaining in stride(from: 0.0, through: Countdown.maxDuration, by: 0.5) {
            #expect(TimerDisplay.text(remaining: remaining).count
                    <= TimerDisplay.widestText.count)
        }
    }
}
