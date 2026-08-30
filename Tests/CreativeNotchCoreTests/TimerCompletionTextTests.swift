import Foundation
import Testing
@testable import CreativeNotchCore

struct TimerCompletionTextTests {
    @Test func anOnTimeTimerJustNamesItsDuration() {
        let c = TimerCompletion(duration: 1500, lateness: 0)
        #expect(TimerCompletionText.detail(for: c) == "25m")
    }

    /// Sub-minute lateness is scheduler jitter, not information.
    @Test func trivialLatenessIsNotMentioned() {
        let c = TimerCompletion(duration: 1500, lateness: 12)
        #expect(TimerCompletionText.detail(for: c) == "25m")
    }

    /// The spec's honesty requirement: a timer that fired late because the
    /// machine slept must say so rather than present a stale event as
    /// current.
    @Test func realLatenessIsReported() {
        #expect(TimerCompletionText.detail(for: .init(duration: 1500, lateness: 300))
                == "25m · finished 5m ago")
        #expect(TimerCompletionText.detail(for: .init(duration: 1500, lateness: 7200))
                == "25m · finished 2h ago")
    }

    @Test func latenessOverADayStillReadsSensibly() {
        #expect(TimerCompletionText.detail(for: .init(duration: 600, lateness: 90_000))
                == "10m · finished 25h ago")
    }

    /// The hour boundary itself: at exactly 60 minutes late this must read
    /// as an hour, not "60m". Pins the `>=` in the hours check — a `>` there
    /// reads identically for every other case in this file, since none of
    /// them land on the boundary.
    @Test func latenessAtExactlyOneHourReadsAsAnHour() {
        #expect(TimerCompletionText.detail(for: .init(duration: 1500, lateness: 3600))
                == "25m · finished 1h ago")
    }
}
