import AppKit
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// Restart policy for a subprocess that is expected to fail sometimes.
///
/// Nothing here sleeps and nothing spawns: the retry scheduler is injected
/// and captured, so the whole policy is asserted by inspecting what was
/// *asked for* — the same shape as `ClipboardPoller`'s injected timer.
@MainActor
struct MediaHelperSupervisorTests {

    private final class Box {
        var starts = 0
        var stops = 0
        var scheduled: [TimeInterval] = []
        var pending: (@MainActor () -> Void)?
        var degraded = false
    }

    private func makeSupervisor() -> (MediaHelperSupervisor, Box) {
        let box = Box()
        let s = MediaHelperSupervisor()
        s.startHelper = { box.starts += 1 }
        s.stopHelper = { box.stops += 1 }
        s.scheduleRetry = { delay, work in
            box.scheduled.append(delay)
            box.pending = work
        }
        s.onDegraded = { box.degraded = true }
        return (s, box)
    }

    @Test func startingStartsTheHelper() {
        let (s, box) = makeSupervisor()
        s.start()
        #expect(box.starts == 1)
    }

    @Test func anUnexpectedExitSchedulesARetryAtTheFirstDelay() {
        let (s, box) = makeSupervisor()
        s.start()
        s.helperExited(status: 1)

        #expect(box.scheduled == [HelperBackoff.delay(forAttempt: 1)])
        #expect(box.starts == 1, "the retry has not fired yet")
    }

    @Test func theScheduledRetryStartsTheHelperAgain() {
        let (s, box) = makeSupervisor()
        s.start()
        s.helperExited(status: 1)
        box.pending?()

        #expect(box.starts == 2)
    }

    @Test func delaysFollowTheBackoffSchedule() {
        let (s, box) = makeSupervisor()
        s.start()
        for _ in 1...HelperBackoff.maxAttempts {
            s.helperExited(status: 1)
            box.pending?()
        }
        #expect(box.scheduled == (1...HelperBackoff.maxAttempts).compactMap {
            HelperBackoff.delay(forAttempt: $0)
        })
    }

    /// Giving up is a feature: transport controls need none of this and
    /// keep working, so a permanent retry loop would burn power for a
    /// capability the user is not getting.
    @Test func exhaustingTheAttemptsDegradesInsteadOfRetryingForever() {
        let (s, box) = makeSupervisor()
        s.start()
        for _ in 1...(HelperBackoff.maxAttempts + 1) {
            s.helperExited(status: 1)
            box.pending?()
        }

        #expect(box.degraded)
        #expect(s.isDegraded)
        #expect(box.scheduled.count == HelperBackoff.maxAttempts)
    }

    /// A helper that ran fine and then died much later is not the fifth
    /// failure of a crash loop; the counter resets on a healthy run.
    @Test func aSuccessfulRunResetsTheAttemptCount() {
        let (s, _) = makeSupervisor()
        s.start()
        s.helperExited(status: 1)
        #expect(s.attempt == 1)

        s.noteHealthy()
        #expect(s.attempt == 0)
    }

    /// A deliberate stop must not look like a crash and trigger a restart.
    @Test func stoppingDoesNotScheduleARetry() {
        let (s, box) = makeSupervisor()
        s.start()
        s.stop()
        s.helperExited(status: 0)

        #expect(box.scheduled.isEmpty)
        #expect(box.stops == 1)
    }
}
