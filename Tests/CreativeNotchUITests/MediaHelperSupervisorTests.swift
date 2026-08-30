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
        /// Moved by hand rather than by sleeping — see `MediaHelperSupervisor.now`.
        var clock: TimeInterval = 0
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
        s.now = { box.clock }
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

    // MARK: - Duration-based "healthy" (regression fix)
    //
    // `noteHealthy()` used to reset on any decodable line, unconditionally.
    // `bridge.m` emits one line immediately on spawn, so that made
    // `HelperBackoff.maxAttempts` unreachable: a helper that emits its
    // startup line and dies right away, every retry, reset the budget
    // every time and never degraded. The fix is a DURATION notion of
    // healthy — see `MediaHelperSupervisor.noteHealthy()`'s doc comment.

    /// THE REGRESSION. A helper that reports in immediately on every
    /// single (re)spawn and then dies must still reach degradation, even
    /// though real wall-clock time (1s, 2s, 4s, 8s, 16s — 31s of it by the
    /// last iteration) genuinely passes between retries. That last part
    /// matters: it proves the "healthy" clock is anchored to the CURRENT
    /// spawn, not to the original `start()` — if `startedAt` were not
    /// refreshed on every retry, the cumulative 31s would look like more
    /// than enough uptime and this loop would spuriously earn a reset,
    /// never degrading either, just for a subtler reason.
    @Test func aLineEmittedImmediatelyOnEverySpawnDoesNotPreventDegradation() {
        let (s, box) = makeSupervisor()
        s.start()

        for _ in 1...(HelperBackoff.maxAttempts + 1) {
            // The helper that was just (re)spawned reports in immediately,
            // then dies — no time passes between its spawn and this pair,
            // exactly as `bridge.m` does when the helper is failing.
            s.noteHealthy()
            s.helperExited(status: 1)
            if let waited = box.scheduled.last { box.clock += waited }
            box.pending?()
        }

        #expect(s.isDegraded)
        #expect(box.degraded)
    }

    /// A helper that survives past the delay it was made to wait for,
    /// before reporting in, gets the crash-loop cap reset — it is not the
    /// Nth failure of a tight loop, it is a helper that recovered.
    @Test func aRunThatOutlastsItsBackoffDelayGetsAFreshAttemptBudget() {
        let (s, box) = makeSupervisor()
        s.start()

        // Four failures, one short of the cap, each dying the instant it
        // is respawned — like the crash loop above, so none of these
        // earns a reset.
        for _ in 1..<HelperBackoff.maxAttempts {
            s.helperExited(status: 1)
            box.clock += box.scheduled.last!
            box.pending?()
        }
        #expect(s.attempt == HelperBackoff.maxAttempts - 1)

        // This time the respawned helper actually stays up — past the
        // delay it was made to wait for — before its line arrives.
        box.clock += HelperBackoff.delay(forAttempt: s.attempt)! + 1
        s.noteHealthy()
        #expect(s.attempt == 0, "a helper that outlived its backoff delay must get a fresh budget")

        // So the full budget is back: four more instant deaths must not
        // degrade it.
        for _ in 1..<HelperBackoff.maxAttempts {
            s.helperExited(status: 1)
            box.pending?()
        }
        #expect(s.isDegraded == false)
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

    /// A retry already scheduled before `stop()` must not outlive it —
    /// otherwise the helper comes back after an explicit stop, and
    /// because that resurrection bypasses `start()`, the next genuine
    /// crash of it would be misread as another deliberate shutdown.
    @Test func stoppingCancelsAPendingRetry() {
        let (s, box) = makeSupervisor()
        s.start()
        s.helperExited(status: 1)   // schedules a retry
        s.stop()                     // must invalidate it
        box.pending?()                // fire the stale retry anyway

        #expect(box.starts == 1, "a stale retry must not resurrect the helper after stop()")
    }

    /// The other half of the same bug: proving the cancellation above
    /// does not also disable retries permanently. After a stop and a
    /// later legitimate `start()`, a genuine crash must still be
    /// scheduled for retry, not silently swallowed.
    @Test func aGenuineCrashAfterRestartingFollowingAStopIsStillHandled() {
        let (s, box) = makeSupervisor()
        s.start()
        s.helperExited(status: 1)
        s.stop()
        box.pending?()

        box.scheduled.removeAll()
        s.start()
        s.helperExited(status: 1)

        #expect(box.scheduled.count == 1, "a crash after a legitimate restart must still be retried")
    }
}
