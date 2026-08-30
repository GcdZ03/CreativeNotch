import Foundation
import Testing
@testable import CreativeNotchCore

struct TimerScheduleTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private func c(_ d: TimeInterval) -> Countdown { Countdown(duration: d, startingAt: t0)! }

    @Test func nothingIsScheduledWithoutATimer() {
        #expect(TimerSchedule.nextWake(countdown: nil, isActive: true, at: t0) == nil)
    }

    @Test func anActiveScreenWakesOnTheNextDisplayChange() throws {
        #expect(try #require(TimerSchedule.nextWake(countdown: c(1500), isActive: true, at: t0)) == 60)
    }

    /// The exemption: with the screen asleep there is no observer, so the
    /// per-minute redraws are skipped -- but the deadline is NOT.
    @Test func aSleepingScreenWakesOnlyAtTheDeadline() throws {
        #expect(try #require(TimerSchedule.nextWake(countdown: c(1500), isActive: false, at: t0)) == 1500)
    }

    @Test func aPausedTimerSchedulesNothingEitherWay() {
        let paused = c(1500).paused(at: t0)
        #expect(TimerSchedule.nextWake(countdown: paused, isActive: true, at: t0) == nil)
        #expect(TimerSchedule.nextWake(countdown: paused, isActive: false, at: t0) == nil)
    }

    @Test func aFinishedTimerSchedulesNothing() {
        #expect(TimerSchedule.nextWake(countdown: c(60), isActive: true,
                                       at: t0.addingTimeInterval(120)) == nil)
    }

    /// Near the end the display change comes before the deadline, and the
    /// earlier of the two must win or the last second never renders.
    @Test func theEarlierOfDisplayChangeAndDeadlineWins() throws {
        let wake = try #require(TimerSchedule.nextWake(countdown: c(30), isActive: true, at: t0))
        #expect(wake == 1)
    }

    @Test func aWakeIsNeverScheduledPastTheDeadline() throws {
        for remaining in stride(from: 0.5, through: 300, by: 0.5) {
            let started = Countdown(duration: remaining, startingAt: t0)!
            let wake = try #require(TimerSchedule.nextWake(countdown: started, isActive: true, at: t0))
            #expect(wake <= remaining + 0.0001, "overshot at \(remaining)")
            #expect(wake > 0)
        }
    }

    /// The schedule is derived from the instant asked about, not from the
    /// duration the countdown was created with: 90 seconds into a 25-minute
    /// timer the ear reads `24m` and next changes 30 seconds later, not 60.
    @Test func theScheduleFollowsTheClockRatherThanTheStart() throws {
        let wake = try #require(TimerSchedule.nextWake(
            countdown: c(1500), isActive: true, at: t0.addingTimeInterval(90)
        ))
        #expect(wake == 30)
    }

    /// The deadline is read from the clock too, so a machine that slept
    /// through most of a countdown wakes for what is left rather than for
    /// the full duration.
    @Test func aSleepingScreenWakesAtWhatIsLeftNotTheFullDuration() throws {
        let wake = try #require(TimerSchedule.nextWake(
            countdown: c(1500), isActive: false, at: t0.addingTimeInterval(1400)
        ))
        #expect(wake == 100)
    }
}
