import Foundation
import Testing
@testable import CreativeNotchCore

struct CountdownTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    @Test func remainingCountsDownFromTheTarget() throws {
        let c = try #require(Countdown(duration: 1500, startingAt: t0))
        #expect(c.remaining(at: t0) == 1500)
        #expect(c.remaining(at: t0.addingTimeInterval(500)) == 1000)
    }

    /// The whole reason a target Date is stored rather than a tick count.
    /// A machine asleep for an hour must come back with the right number,
    /// not one an hour stale.
    @Test func remainingIsDerivedFromTheClockSoSleepCannotLoseTime() throws {
        let c = try #require(Countdown(duration: 1500, startingAt: t0))
        #expect(c.remaining(at: t0.addingTimeInterval(3600)) == -2100)
        #expect(c.hasFinished(at: t0.addingTimeInterval(3600)))
    }

    @Test func remainingIsNotClampedSoLatenessIsMeasurable() throws {
        let c = try #require(Countdown(duration: 60, startingAt: t0))
        // The completion peek reports how late it fired; clamping to zero
        // would throw that away.
        #expect(c.remaining(at: t0.addingTimeInterval(120)) == -60)
    }

    @Test func aTimerHasNotFinishedBeforeItsTarget() throws {
        let c = try #require(Countdown(duration: 60, startingAt: t0))
        #expect(!c.hasFinished(at: t0.addingTimeInterval(59.9)))
        #expect(c.hasFinished(at: t0.addingTimeInterval(60)))
    }

    @Test func durationsOutsideTheAllowedRangeAreRejected() {
        #expect(Countdown(duration: 0, startingAt: t0) == nil)
        #expect(Countdown(duration: -60, startingAt: t0) == nil)
        #expect(Countdown(duration: Countdown.maxDuration + 1, startingAt: t0) == nil)
        #expect(Countdown(duration: Countdown.maxDuration, startingAt: t0) != nil)
    }

    @Test func pausingFreezesTheRemainingTime() throws {
        let c = try #require(Countdown(duration: 1500, startingAt: t0))
            .paused(at: t0.addingTimeInterval(500))
        #expect(c.isPaused)
        // Time passing while paused changes nothing.
        #expect(c.remaining(at: t0.addingTimeInterval(500)) == 1000)
        #expect(c.remaining(at: t0.addingTimeInterval(5000)) == 1000)
    }

    @Test func resumingPushesTheTargetOutByTheTimeSpentPaused() throws {
        let c = try #require(Countdown(duration: 1500, startingAt: t0))
            .paused(at: t0.addingTimeInterval(500))
            .resumed(at: t0.addingTimeInterval(3000))
        #expect(!c.isPaused)
        #expect(c.remaining(at: t0.addingTimeInterval(3000)) == 1000)
    }

    @Test func pausingTwiceDoesNotCompoundTheFreeze() throws {
        let c = try #require(Countdown(duration: 1500, startingAt: t0))
            .paused(at: t0.addingTimeInterval(500))
            .paused(at: t0.addingTimeInterval(900))
        #expect(c.remaining(at: t0.addingTimeInterval(900)) == 1000)
    }

    @Test func resumingATimerThatIsNotPausedChangesNothing() throws {
        let c = try #require(Countdown(duration: 1500, startingAt: t0))
        #expect(c.resumed(at: t0.addingTimeInterval(500)) == c)
    }

    @Test func aPausedTimerNeverFinishes() throws {
        let c = try #require(Countdown(duration: 60, startingAt: t0))
            .paused(at: t0.addingTimeInterval(30))
        #expect(!c.hasFinished(at: t0.addingTimeInterval(100_000)))
    }
}
