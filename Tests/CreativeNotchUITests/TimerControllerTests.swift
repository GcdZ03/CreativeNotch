import Foundation
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// Every test here drives the controller by moving an injected clock and
/// calling the public API. Nothing sleeps and nothing waits on real time:
/// the outstanding one-shot is observed through `scheduledWake`, which is
/// written synchronously as the task is spawned.
@MainActor
struct TimerControllerTests {
    private final class Clock { var now = Date(timeIntervalSinceReferenceDate: 1_000_000) }

    @Test func startingPublishesTheCountdown() {
        let clock = Clock()
        let c = TimerController(now: { clock.now })
        var published: [Countdown?] = []
        c.onChange = { published.append($0) }

        c.start(duration: 600)
        #expect(c.countdown != nil)
        #expect(published.count == 1)
    }

    @Test func anOverlongDurationStartsNothing() {
        let clock = Clock()
        let c = TimerController(now: { clock.now })
        c.start(duration: Countdown.maxDuration + 60)
        #expect(c.countdown == nil)
    }

    @Test func cancellingClearsIt() {
        let clock = Clock()
        let c = TimerController(now: { clock.now })
        c.start(duration: 600)
        c.cancel()
        #expect(c.countdown == nil)
    }

    @Test func pausingAndResumingPreservesTheRemainder() {
        let clock = Clock()
        let c = TimerController(now: { clock.now })
        c.start(duration: 600)
        clock.now = clock.now.addingTimeInterval(100)
        c.pause()
        clock.now = clock.now.addingTimeInterval(10_000)
        c.resume()
        #expect(c.countdown?.remaining(at: clock.now) == 500)
    }

    // MARK: - The one-shot

    /// A running timer holds exactly one outstanding wake, and it is the
    /// next display change rather than a one-second tick.
    @Test func startingSchedulesOneWakeAtTheNextDisplayChange() {
        let clock = Clock()
        let c = TimerController(now: { clock.now })
        c.start(duration: 1500)
        #expect(c.scheduledWake == 60)
    }

    /// The spec's claim that a paused timer redraws zero times, made to
    /// bite: pausing publishes the frozen value once and then schedules
    /// nothing at all.
    @Test func aPausedTimerSchedulesNoWake() {
        let clock = Clock()
        let c = TimerController(now: { clock.now })
        var published: [Countdown?] = []
        c.onChange = { published.append($0) }

        c.start(duration: 1500)
        #expect(c.scheduledWake == 60)
        c.pause()
        #expect(c.scheduledWake == nil)
        // One for the start, one for the pause, and nothing periodic.
        #expect(published.count == 2)
    }

    @Test func resumingSchedulesAgain() {
        let clock = Clock()
        let c = TimerController(now: { clock.now })
        c.start(duration: 1500)
        c.pause()
        clock.now = clock.now.addingTimeInterval(10_000)
        c.resume()
        #expect(c.scheduledWake == 60)
    }

    /// Rescheduling replaces the outstanding one-shot rather than stacking a
    /// second one beside it. Two live chains would each spawn their own
    /// successor, doubling the wake rate on every activity flip.
    @Test func reschedulingCancelsTheOutstandingWake() throws {
        let clock = Clock()
        let c = TimerController(now: { clock.now })
        c.start(duration: 1500)
        let first = try #require(c.pending)
        #expect(!first.isCancelled)

        c.setActive(false)
        #expect(first.isCancelled)
        let second = try #require(c.pending)
        #expect(!second.isCancelled)

        c.pause()
        #expect(second.isCancelled)
        #expect(c.pending == nil)
    }

    @Test func cancellingCancelsTheOutstandingWake() throws {
        let clock = Clock()
        let c = TimerController(now: { clock.now })
        c.start(duration: 1500)
        let first = try #require(c.pending)

        c.cancel()
        #expect(first.isCancelled)
        #expect(c.pending == nil)
    }

    @Test func cancellingSchedulesNothing() {
        let clock = Clock()
        let c = TimerController(now: { clock.now })
        c.start(duration: 1500)
        c.cancel()
        #expect(c.scheduledWake == nil)
    }

    // MARK: - The SystemActivity exemption

    /// The exemption, at the controller: the screen going to sleep does not
    /// suspend the timer the way it suspends the poller. It reschedules
    /// from the display change to the deadline, and back again on wake.
    @Test func theScreenSleepingReschedulesToTheDeadline() {
        let clock = Clock()
        let c = TimerController(now: { clock.now })
        c.start(duration: 1500)
        #expect(c.scheduledWake == 60)

        c.setActive(false)
        #expect(c.scheduledWake == 1500)
        #expect(c.countdown != nil)

        c.setActive(true)
        #expect(c.scheduledWake == 60)
    }

    /// Rescheduling on an activity change must not publish a redraw: the
    /// value did not change, only when we next intend to look at it.
    @Test func changingActivityDoesNotRedraw() {
        let clock = Clock()
        let c = TimerController(now: { clock.now })
        c.start(duration: 1500)
        var published: [Countdown?] = []
        c.onChange = { published.append($0) }

        c.setActive(false)
        c.setActive(true)
        #expect(published.isEmpty)
    }

    /// An inactive screen still gets no wake for a paused timer — the
    /// exemption is about the deadline, and a paused timer has none.
    @Test func aPausedTimerSchedulesNothingWithTheScreenAsleepEither() {
        let clock = Clock()
        let c = TimerController(now: { clock.now })
        c.start(duration: 1500)
        c.pause()
        c.setActive(false)
        #expect(c.scheduledWake == nil)
    }

    // MARK: - Completion

    /// The deadline is decided by the clock, not by the one-shot having
    /// fired: any reschedule that finds the target already past completes
    /// the timer. This is what makes a machine that slept through the
    /// deadline fire on wake rather than never.
    @Test func aDeadlineAlreadyPastCompletesOnTheNextReschedule() {
        let clock = Clock()
        let c = TimerController(now: { clock.now })
        var published: [Countdown?] = []
        var finished: [Countdown] = []
        c.start(duration: 60)
        c.onChange = { published.append($0) }
        c.onFinished = { finished.append($0) }

        clock.now = clock.now.addingTimeInterval(61)
        c.setActive(false)

        #expect(finished.count == 1)
        #expect(finished.first?.duration == 60)
        #expect(c.countdown == nil)
        #expect(published == [nil])
        #expect(c.scheduledWake == nil)
    }

    /// The completion carries how late it fired, which is why
    /// `Countdown.remaining` is unclamped.
    @Test func aLateCompletionStillReportsTheTimerThatFired() {
        let clock = Clock()
        let c = TimerController(now: { clock.now })
        var finished: [Countdown] = []
        c.onFinished = { finished.append($0) }
        c.start(duration: 300)

        // The machine slept for an hour through a five-minute timer.
        clock.now = clock.now.addingTimeInterval(3600)
        c.setActive(false)

        #expect(finished.count == 1)
        #expect(finished.first?.remaining(at: clock.now) == -3300)
    }

    /// Completion fires once, not once per subsequent reschedule.
    @Test func completionDoesNotFireTwice() {
        let clock = Clock()
        let c = TimerController(now: { clock.now })
        var finished: [Countdown] = []
        c.onFinished = { finished.append($0) }
        c.start(duration: 60)

        clock.now = clock.now.addingTimeInterval(61)
        c.setActive(false)
        c.setActive(true)
        c.pause()
        c.resume()

        #expect(finished.count == 1)
    }
}
