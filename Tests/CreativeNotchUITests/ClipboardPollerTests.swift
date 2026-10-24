import AppKit
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// The project's one admitted timer (spec section 5.3).
///
/// Nothing here sleeps. `tick(now:)` carries the whole decision and is
/// called directly, and the timer is injected the way
/// `AppDelegate.installOutsideClickMonitor` is — so scheduling is asserted
/// by inspecting what the poller *asked* for rather than by waiting.
@MainActor
struct ClipboardPollerTests {

    /// A stand-in for `Timer` that records rather than fires.
    private final class FakeTimer {
        let interval: TimeInterval
        var cancelled = false
        init(interval: TimeInterval) { self.interval = interval }
    }

    private final class Box {
        var captured: [ClipboardContent] = []
        var timers: [FakeTimer] = []
        var frontmost: String?
        var frontmostReads = 0
    }

    private struct Harness {
        let poller: ClipboardPoller
        let pasteboard: NSPasteboard
        let box: Box

        var captured: [ClipboardContent] { box.captured }
        var timers: [FakeTimer] { box.timers }

        /// What a real app does when it copies.
        ///
        /// `clearContents()` is what bumps `changeCount`; `setString`
        /// alone does not. Since `changeCount` is the entire mechanism the
        /// poller keys on, a test that only calls `setString` simulates
        /// nothing and passes whatever the poller does.
        func copy(_ string: String, type: NSPasteboard.PasteboardType = .string) {
            pasteboard.clearContents()
            pasteboard.setString(string, forType: type)
        }
    }

    private func makeHarness(lowPower: Bool = false) -> Harness {
        let pb = NSPasteboard(name: NSPasteboard.Name("CreativeNotchPollTest-\(UUID().uuidString)"))
        pb.clearContents()

        let poller = ClipboardPoller(pasteboard: pb)
        let box = Box()

        poller.isLowPowerMode = { lowPower }
        poller.onCapture = { box.captured.append($0) }
        poller.scheduleTimer = { interval, _ in
            let timer = FakeTimer(interval: interval)
            box.timers.append(timer)
            return timer
        }
        poller.cancelTimer = { ($0 as? FakeTimer)?.cancelled = true }
        // Nothing in front unless a test says so: the real answer depends on
        // whatever the developer has open.
        poller.frontmostApp = { box.frontmostReads += 1; return box.frontmost }

        return Harness(poller: poller, pasteboard: pb, box: box)
    }

    // MARK: - Capturing

    @Test func aChangedPasteboardIsCaptured() {
        let h = makeHarness()
        h.poller.start(now: 0)
        h.copy("hello")
        h.poller.tick(now: 1)

        #expect(h.captured == [.text("hello")])
    }

    /// The `changeCount` guard is what makes a 0.75s timer acceptable:
    /// almost every tick does one integer comparison and stops.
    @Test func anUnchangedPasteboardIsNotRead() {
        let h = makeHarness()
        h.copy("hello")
        h.poller.start(now: 0)

        h.poller.tick(now: 1)
        h.poller.tick(now: 2)

        #expect(h.captured.isEmpty)
    }

    /// Starting adopts whatever is already on the pasteboard as the
    /// baseline without capturing it. Launching the app must not sweep in
    /// whatever happened to be copied beforehand.
    @Test func startingDoesNotCaptureWhatWasAlreadyThere() {
        let h = makeHarness()
        h.copy("from before launch")
        h.poller.start(now: 0)
        h.poller.tick(now: 1)

        #expect(h.captured.isEmpty)
    }

    @Test func successiveChangesAreEachCaptured() {
        let h = makeHarness()
        h.poller.start(now: 0)

        h.copy("one")
        h.poller.tick(now: 1)

        h.copy("two")
        h.poller.tick(now: 2)

        #expect(h.captured == [.text("one"), .text("two")])
    }

    /// A concealed copy is not captured, but it *is* activity. The
    /// back-off measures time since anything changed, so a password
    /// manager copy must reset it — otherwise the poller crawls at the
    /// idle rate exactly when the user is busiest.
    @Test func aRefusedChangeStillCountsAsActivity() {
        let h = makeHarness()
        h.poller.start(now: 0)
        h.poller.tick(now: 300)
        #expect(h.poller.scheduledInterval == ClipboardPollSchedule.idleInterval)

        h.copy("secret", type: .nsConcealed)
        h.poller.tick(now: 301)

        #expect(h.captured.isEmpty)
        #expect(h.poller.scheduledInterval == ClipboardPollSchedule.activeInterval)
    }

    // MARK: - Suspension

    @Test func aSuspendedPollerCapturesNothing() {
        let h = makeHarness()
        h.poller.start(now: 0)
        h.poller.setActivity(.locked, now: 1)

        h.copy("while locked")
        h.poller.tick(now: 2)

        #expect(h.captured.isEmpty)
    }

    @Test func suspendingCancelsTheTimer() {
        let h = makeHarness()
        h.poller.start(now: 0)
        h.poller.setActivity(.asleep, now: 1)

        // Hoisted out of `#expect`: `allSatisfy` is `rethrows`, and the
        // macro's expansion cannot see that a key-path predicate never
        // throws.
        let allCancelled = h.timers.allSatisfy(\.cancelled)
        #expect(h.poller.scheduledInterval == nil)
        #expect(allCancelled)
    }

    /// The behaviour this task exists for. Something was copied while the
    /// screen was locked; on unlock the baseline moves forward and that
    /// content is never read.
    @Test func resumingResyncsWithoutCapturing() {
        let h = makeHarness()
        h.poller.start(now: 0)
        h.poller.setActivity(.locked, now: 1)

        h.copy("copied while locked")

        h.poller.setActivity(.active, now: 2)
        h.poller.tick(now: 3)

        #expect(h.captured.isEmpty)
    }

    /// Resuming must not deafen the poller to what comes next.
    @Test func aChangeAfterResumingIsCaptured() {
        let h = makeHarness()
        h.poller.start(now: 0)
        h.poller.setActivity(.locked, now: 1)
        h.copy("copied while locked")
        h.poller.setActivity(.active, now: 2)

        h.copy("copied after unlock")
        h.poller.tick(now: 3)

        #expect(h.captured == [.text("copied after unlock")])
    }

    @Test func resumingRestartsTheTimer() {
        let h = makeHarness()
        h.poller.start(now: 0)
        h.poller.setActivity(.locked, now: 1)
        h.poller.setActivity(.active, now: 2)

        #expect(h.poller.scheduledInterval == ClipboardPollSchedule.activeInterval)
    }

    /// The resume treats the moment of resuming as the last change, so a
    /// machine that slept for a week does not come back polling at the
    /// idle rate.
    @Test func resumingResetsTheBackOffClock() {
        let h = makeHarness()
        h.poller.start(now: 0)
        h.poller.setActivity(.asleep, now: 1)
        h.poller.setActivity(.active, now: 1_000_000)

        #expect(h.poller.scheduledInterval == ClipboardPollSchedule.activeInterval)
    }

    /// Starting while suspended must not schedule. The switchboard fans
    /// the activity out to the poller even while the module is off, so
    /// switching clipboard history on behind the lock screen reaches
    /// `start` with the poller already `.locked` — and a timer scheduled
    /// then would fire every 0.75s until unlock, because `tick` returns
    /// before it reaches the reschedule that could slow it down.
    @Test func startingWhileSuspendedSchedulesNothing() {
        let h = makeHarness()
        h.poller.setActivity(.locked, now: 0)
        h.poller.start(now: 1)

        #expect(h.poller.scheduledInterval == nil)
        #expect(h.timers.isEmpty)
    }

    /// And the deferred start is honoured on resume.
    @Test func aStartWhileSuspendedBeginsPollingOnResume() {
        let h = makeHarness()
        h.poller.setActivity(.asleep, now: 0)
        h.poller.start(now: 1)
        h.poller.setActivity(.active, now: 2)

        #expect(h.poller.scheduledInterval == ClipboardPollSchedule.activeInterval)
    }

    @Test func anUnchangedActivityDoesNotRebuildTheTimer() {
        let h = makeHarness()
        h.poller.start(now: 0)
        let before = h.timers.count
        h.poller.setActivity(.active, now: 1)

        #expect(h.timers.count == before)
    }

    // MARK: - Scheduling

    @Test func startingSchedulesAtTheActiveRate() {
        let h = makeHarness()
        h.poller.start(now: 0)

        #expect(h.poller.scheduledInterval == ClipboardPollSchedule.activeInterval)
        #expect(h.timers.last?.interval == ClipboardPollSchedule.activeInterval)
    }

    @Test func aQuietSpellBacksTheTimerOff() {
        let h = makeHarness()
        h.poller.start(now: 0)
        h.poller.tick(now: ClipboardPollSchedule.idleAfter + 1)

        #expect(h.poller.scheduledInterval == ClipboardPollSchedule.idleInterval)
        #expect(h.timers.last?.interval == ClipboardPollSchedule.idleInterval)
    }

    @Test func aChangeAfterBackingOffReturnsToTheActiveRate() {
        let h = makeHarness()
        h.poller.start(now: 0)
        h.poller.tick(now: 300)
        #expect(h.poller.scheduledInterval == ClipboardPollSchedule.idleInterval)

        h.copy("something")
        h.poller.tick(now: 301)

        #expect(h.poller.scheduledInterval == ClipboardPollSchedule.activeInterval)
    }

    /// The timer is rebuilt only when the wanted interval actually
    /// changes. Rebuilding on every tick would mean tearing down and
    /// recreating a `Timer` roughly once a second, all day.
    @Test func anUnchangedIntervalDoesNotRebuildTheTimer() {
        let h = makeHarness()
        h.poller.start(now: 0)
        let before = h.timers.count

        h.poller.tick(now: 1)
        h.poller.tick(now: 2)

        #expect(h.timers.count == before)
    }

    @Test func lowPowerModeRaisesTheScheduledInterval() {
        let h = makeHarness(lowPower: true)
        h.poller.start(now: 0)

        #expect(h.poller.scheduledInterval == ClipboardPollSchedule.lowPowerFloor)
    }

    // MARK: - Lifecycle

    @Test func stoppingCancelsTheTimer() {
        let h = makeHarness()
        h.poller.start(now: 0)
        h.poller.stop()

        let allCancelled = h.timers.allSatisfy(\.cancelled)
        #expect(h.poller.scheduledInterval == nil)
        #expect(allCancelled)
    }

    @Test func aStoppedPollerCapturesNothing() {
        let h = makeHarness()
        h.poller.start(now: 0)
        h.poller.stop()

        h.copy("after stop")
        h.poller.tick(now: 1)

        #expect(h.captured.isEmpty)
    }

    @Test func startingTwiceDoesNotStackTimers() {
        let h = makeHarness()
        h.poller.start(now: 0)
        h.poller.start(now: 1)

        #expect(h.timers.count == 2)
        #expect(h.timers.first?.cancelled == true)
        #expect(h.timers.last?.cancelled == false)
    }

    @Test func stoppingWithoutStartingIsHarmless() {
        let h = makeHarness()
        h.poller.stop()
        #expect(h.poller.scheduledInterval == nil)
    }

    // MARK: - Excluded apps (2026-10-24)

    @Test func aCopyMadeInAnExcludedFrontmostAppIsNotCaptured() {
        let h = makeHarness()
        h.poller.excludedApps = { ["com.apple.Terminal"] }
        h.box.frontmost = "com.apple.Terminal"
        h.poller.start(now: 0)
        h.copy("token")
        h.poller.tick(now: 1)

        #expect(h.captured.isEmpty)

        // Another app in front, and copies are recorded again.
        h.box.frontmost = "com.apple.Safari"
        h.copy("hello")
        h.poller.tick(now: 2)
        #expect(h.captured == [.text("hello")])
    }

    /// `org.nspasteboard.source` names the copying app even when it is not
    /// in front -- a menu bar password manager.
    @Test func aCopyDeclaringAnExcludedSourceIsNotCaptured() {
        let h = makeHarness()
        h.poller.excludedApps = { ["com.example.vault"] }
        h.box.frontmost = "com.apple.Safari"
        h.poller.start(now: 0)

        h.pasteboard.clearContents()
        h.pasteboard.setString("hunter2", forType: .string)
        h.pasteboard.setString("com.example.vault", forType: .nsSource)
        h.poller.tick(now: 1)

        #expect(h.captured.isEmpty)
    }

    /// The frontmost app is read only when the pasteboard changed and the
    /// list has something in it -- never on an idle tick, and never at all
    /// for the people who left the list empty.
    @Test func theFrontmostAppIsReadOnlyForAChangeWithAList() {
        let h = makeHarness()
        h.poller.start(now: 0)
        h.copy("one")
        h.poller.tick(now: 1)
        #expect(h.box.frontmostReads == 0)

        h.poller.excludedApps = { ["com.apple.Terminal"] }
        h.poller.tick(now: 2)
        h.poller.tick(now: 3)
        #expect(h.box.frontmostReads == 0)

        h.copy("two")
        h.poller.tick(now: 4)
        #expect(h.box.frontmostReads == 1)
    }

    /// Refused for its app, the copy is still activity, like a concealed
    /// one: the back-off measures time since anything changed.
    @Test func anExcludedCopyStillCountsAsActivity() {
        let h = makeHarness()
        h.poller.excludedApps = { ["com.apple.Terminal"] }
        h.box.frontmost = "com.apple.Terminal"
        h.poller.start(now: 0)
        h.poller.tick(now: 300)
        #expect(h.poller.scheduledInterval == ClipboardPollSchedule.idleInterval)

        h.copy("token")
        h.poller.tick(now: 301)

        #expect(h.captured.isEmpty)
        #expect(h.poller.scheduledInterval == ClipboardPollSchedule.activeInterval)
    }
}
