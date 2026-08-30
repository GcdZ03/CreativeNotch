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

    /// The `ceil` in `text` only shows up at fractional remainders: with
    /// whole seconds `ceil == floor`, so the other rounding tests pass
    /// under either. At 1440.5s ceiling reads "25m" and floor reads "24m" —
    /// the display would drop a minute early.
    @Test func aFractionalRemainderRoundsUpNotDown() {
        #expect(TimerDisplay.text(remaining: 1440.5) == "25m")
        #expect(TimerDisplay.text(remaining: 60.5) == "2m")
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

    /// Every scheduled wake lands on the *first* instant the string changes,
    /// at every scale — which is four separate claims, all of them needed.
    ///
    /// `before != after` alone catches only a wake that is too **early**: a
    /// delay that is far too long still lands on a different string, so a
    /// schedule that overshot the deadline or skipped an entire minute
    /// passed this loop while the display sat frozen. Both were live
    /// mutations that survived a green suite.
    ///
    /// So the wake is pinned from both sides:
    ///
    /// - `delay > 0` — never a wake in the past.
    /// - `delay <= remaining` — never past the deadline. A timer over ~33
    ///   minutes could overshoot by a second and still land on `"0:00"`,
    ///   which differs from `"34m"` and satisfies the inequality below.
    /// - `before != after` — the wake really is a change.
    /// - the text is *still* `before` a hair earlier — the wake is the
    ///   change's first instant, not a late one. This is the assertion that
    ///   catches a skipped boundary: a delay long enough to jump a minute
    ///   means the string had already changed before we woke.
    ///
    /// The epsilon is safe on this grid: `remaining - delay` is an exact
    /// integer boundary, and the string is constant across the whole
    /// interval above it.
    @Test func everyScheduledWakeIsTheFirstInstantTheStringChanges() throws {
        for remaining in stride(from: 0.5, through: Countdown.maxDuration, by: 0.5) {
            let delay = try #require(TimerDisplay.nextChange(remaining: remaining))
            let before = TimerDisplay.text(remaining: remaining)
            let after = TimerDisplay.text(remaining: remaining - delay)
            #expect(before != after, "no change at \(remaining) after \(delay)")
            #expect(delay > 0, "non-positive delay at \(remaining)")
            #expect(delay <= remaining,
                    "wakes \(delay - remaining)s past the deadline at \(remaining)")
            #expect(TimerDisplay.text(remaining: remaining - delay + 0.001) == before,
                    "text already changed before the wake at \(remaining) after \(delay)")
        }
    }

    @Test func theWidestTextIsAsWideAsAnythingTheFormatProduces() {
        for remaining in stride(from: 0.0, through: Countdown.maxDuration, by: 0.5) {
            #expect(TimerDisplay.text(remaining: remaining).count
                    <= TimerDisplay.widestText.count)
        }
    }

    /// `widestText` sizes a fixed-width badge, so it must be a string this
    /// format can actually emit — not merely one of the right length. The
    /// format produces "NNm" and "0:SS" and nothing else, so a plausible
    /// wrong value like "1:11" is caught here rather than by eye.
    ///
    /// Kept alongside the count test above, which says something different:
    /// that nothing the format emits is *longer*. Neither implies the other,
    /// and neither is the rendering-width claim `widestText` ultimately
    /// makes — `CreativeNotchCore` links no UI framework and cannot measure
    /// text, so that assertion belongs in a UI test.
    @Test func theWidestTextIsSomethingTheFormatCanProduce() {
        let produced = Set(
            stride(from: 0.0, through: Countdown.maxDuration, by: 0.5)
                .map { TimerDisplay.text(remaining: $0) }
        )
        #expect(produced.contains(TimerDisplay.widestText))
    }
}
