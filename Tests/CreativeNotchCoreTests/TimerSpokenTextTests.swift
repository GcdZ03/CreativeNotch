import Foundation
import Testing
@testable import CreativeNotchCore

/// What VoiceOver hears for the timer: words where the screen shows `25m`
/// and `0:42`, which a screen reader spells out as letters and a ratio.
///
/// Every reading is at the display's own granularity, and that is the
/// property most of these tests pin. The view only redraws when
/// `TimerDisplay.text` changes, so a seconds-precise spoken value would be
/// up to a minute stale by the time VoiceOver read it; matching the digits
/// keeps what is heard true at whatever moment it is heard.
struct TimerSpokenTextTests {

    // MARK: - Durations

    @Test func minutesAreSpokenAsMinutes() {
        #expect(TimerSpokenText.duration(1500) == "25 minutes")
        #expect(TimerSpokenText.duration(60) == "1 minute")
    }

    /// Ceiling, like the digits: a timer with 24m01s left reads `25m`, so it
    /// must be heard as 25 minutes, not 24.
    @Test func minutesRoundUpAsTheDigitsDo() {
        #expect(TimerSpokenText.duration(1441) == "25 minutes")
    }

    @Test func theLastMinuteIsSpokenInSeconds() {
        #expect(TimerSpokenText.duration(42) == "42 seconds")
        #expect(TimerSpokenText.duration(1) == "1 second")
        #expect(TimerSpokenText.duration(0) == "0 seconds")
    }

    /// `remaining` is unclamped upstream; a late read must not say "minus".
    @Test func aNegativeRemainderIsZero() {
        #expect(TimerSpokenText.duration(-30) == "0 seconds")
    }

    // MARK: - The running countdown

    @Test func theValueSaysWhatIsLeftAndHowFarAlong() {
        #expect(TimerSpokenText.value(remaining: 252, isPaused: false, fraction: 0.4)
                == "5 minutes remaining, 40% done")
    }

    /// Paused leads, because dimming is the only visual sign of it and it
    /// changes what the number means.
    @Test func pausedIsSaidFirst() {
        #expect(TimerSpokenText.value(remaining: 42, isPaused: true, fraction: 0.93)
                == "Paused, 42 seconds remaining, 93% done")
    }

    @Test func progressIsAWholePercentage() {
        #expect(TimerSpokenText.value(remaining: 1500, isPaused: false, fraction: 0)
                == "25 minutes remaining, 0% done")
        #expect(TimerSpokenText.value(remaining: 1, isPaused: false, fraction: 0.9996)
                == "1 second remaining, 100% done")
    }

    /// The ear badge has no bar, so it says only the time.
    @Test func theBadgeSaysTheTimeAndWhetherItIsPaused() {
        #expect(TimerSpokenText.remaining(1500, isPaused: false) == "25 minutes remaining")
        #expect(TimerSpokenText.remaining(1500, isPaused: true) == "Timer paused, 25 minutes remaining")
    }

    // MARK: - Completion

    /// The duration as an adjective — "a 25-minute timer" — which is how
    /// the thing that finished is named in speech.
    @Test func anOnTimeCompletionNamesTheTimer() {
        #expect(TimerSpokenText.completion(.init(duration: 1500, lateness: 0))
                == "25-minute timer finished")
        #expect(TimerSpokenText.completion(.init(duration: 30, lateness: 0))
                == "30-second timer finished")
    }

    /// The same floor and the same units as `TimerCompletionText`, so the
    /// spoken and the written peek never disagree about whether it was late.
    @Test func latenessFollowsTheWrittenPeek() {
        #expect(TimerSpokenText.completion(.init(duration: 1500, lateness: 12))
                == "25-minute timer finished")
        #expect(TimerSpokenText.completion(.init(duration: 1500, lateness: 300))
                == "25-minute timer finished 5 minutes ago")
        #expect(TimerSpokenText.completion(.init(duration: 1500, lateness: 60))
                == "25-minute timer finished 1 minute ago")
        #expect(TimerSpokenText.completion(.init(duration: 1500, lateness: 3600))
                == "25-minute timer finished 1 hour ago")
        #expect(TimerSpokenText.completion(.init(duration: 1500, lateness: 7200))
                == "25-minute timer finished 2 hours ago")
    }
}
