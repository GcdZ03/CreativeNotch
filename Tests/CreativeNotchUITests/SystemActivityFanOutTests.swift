import AppKit
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// Spec section 4.7: the sleep/lock gate is "enforced once, here". One
/// observer, fanned out — not one per consumer.
///
/// Two observers would mean two sets of registrations for a single fact,
/// and two independent chances to get the sleep-outranks-lock precedence
/// wrong.
@MainActor
struct SystemActivityFanOutTests {

    private static let notched = ScreenMetrics(
        frame: CGRect(x: 1470, y: 200, width: 1470, height: 956),
        safeAreaTopInset: 38,
        auxiliaryTopLeftWidth: 620,
        auxiliaryTopRightWidth: 620,
        menuBarHeight: 38
    )

    private func makeDelegate() -> AppDelegate {
        let delegate = AppDelegate()
        delegate.growthDelay = .zero
        delegate.shelfDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CreativeNotchFanOut-\(UUID().uuidString)")
        delegate.install(metrics: Self.notched)
        return delegate
    }

    @Test func theDelegateOwnsExactlyOneObserver() {
        let delegate = makeDelegate()
        delegate.activity.start()

        // Four registrations: sleep, wake, lock, unlock. Any more means a
        // second observer is registering alongside this one.
        #expect(delegate.activity.tokenCount == 4)
        delegate.activity.stop()
    }

    /// The clipboard poller must still be gated after the refactor — it is
    /// the behaviour the observer existed for in the first place.
    @Test func lockingStillSuspendsTheClipboardPoller() throws {
        let delegate = makeDelegate()
        let clipboard = try #require(delegate.clipboard)
        clipboard.poller.scheduleTimer = { _, _ in nil }
        clipboard.poller.cancelTimer = { _ in }
        clipboard.start()

        delegate.activity.handle(.screenLocked)

        #expect(clipboard.poller.scheduledInterval == nil)
    }

    @Test func unlockingResumesTheClipboardPoller() throws {
        let delegate = makeDelegate()
        let clipboard = try #require(delegate.clipboard)
        clipboard.poller.scheduleTimer = { _, _ in nil }
        clipboard.poller.cancelTimer = { _ in }
        clipboard.start()

        delegate.activity.handle(.screenLocked)

        // Without this, "resumed correctly" and "was never suspended in
        // the first place" are indistinguishable: `poller.start()` leaves
        // `scheduledInterval` at `activeInterval` by default, so a deleted
        // fan-out would let the post-unlock assertion below pass
        // vacuously. Asserting the suspension actually happened first is
        // what makes the resume assertion mean anything.
        #expect(clipboard.poller.scheduledInterval == nil)

        delegate.activity.handle(.screenUnlocked)

        #expect(clipboard.poller.scheduledInterval == ClipboardPollSchedule.activeInterval)
    }

    /// The media leg of the fan-out. Deleting `self.media?.setActivity(state)`
    /// from `AppDelegate` left all 471 tests green — the helper kept running
    /// through lock and sleep, reading now-playing state nobody could see,
    /// and nothing failed. The counter stands in for the real
    /// `stopHelper`, so no process is involved either way.
    @Test func lockingStopsTheMediaHelper() throws {
        let delegate = makeDelegate()
        let clipboard = try #require(delegate.clipboard)
        clipboard.poller.scheduleTimer = { _, _ in nil }
        clipboard.poller.cancelTimer = { _ in }
        let media = try #require(delegate.media)
        var stops = 0
        var starts = 0
        media.supervisor.stopHelper = { stops += 1 }
        media.supervisor.startHelper = { starts += 1 }

        delegate.activity.handle(.screenLocked)

        #expect(stops == 1)
        #expect(starts == 0)
    }

    /// And it comes back. Without this, a fan-out that stopped the helper
    /// and never restarted it would pass the test above while leaving the
    /// feature dead for the rest of the session.
    @Test func unlockingStartsTheMediaHelperAgain() throws {
        let delegate = makeDelegate()
        let clipboard = try #require(delegate.clipboard)
        clipboard.poller.scheduleTimer = { _, _ in nil }
        clipboard.poller.cancelTimer = { _ in }
        let media = try #require(delegate.media)
        var stops = 0
        var starts = 0
        media.supervisor.stopHelper = { stops += 1 }
        media.supervisor.startHelper = { starts += 1 }

        delegate.activity.handle(.screenLocked)
        #expect(stops == 1, "not suspended is indistinguishable from resumed")

        delegate.activity.handle(.screenUnlocked)

        #expect(starts == 1)
    }

    /// The power leg of the fan-out.
    ///
    /// Deleting `self.media?.setActivity(state)` once left all 471 tests
    /// green while the helper ran on through lock and sleep. This is the
    /// same assertion for the power module: the peek must fall silent
    /// behind a lock screen, and only the fan-out makes it.
    @Test func lockingSilencesThePowerPeek() throws {
        let delegate = makeDelegate()
        let clipboard = try #require(delegate.clipboard)
        clipboard.poller.scheduleTimer = { _, _ in nil }
        clipboard.poller.cancelTimer = { _ in }
        let power = try #require(delegate.power)

        var events: [PowerEvent] = []
        power.onEvent = { events.append($0) }

        power.apply(Self.snapshot(source: .battery), now: 100)
        power.apply(Self.snapshot(source: .wall), now: 200)

        // Without this the assertion below could pass because the peek
        // never fired at all, rather than because the lock silenced it.
        #expect(events == [.pluggedIn(level: 66)])

        delegate.activity.handle(.screenLocked)
        power.apply(Self.snapshot(source: .battery), now: 300)

        #expect(events == [.pluggedIn(level: 66)])
    }

    @Test func unlockingRestoresThePowerPeek() throws {
        let delegate = makeDelegate()
        let clipboard = try #require(delegate.clipboard)
        clipboard.poller.scheduleTimer = { _, _ in nil }
        clipboard.poller.cancelTimer = { _ in }
        let power = try #require(delegate.power)

        var events: [PowerEvent] = []
        power.onEvent = { events.append($0) }

        power.apply(Self.snapshot(source: .battery), now: 100)
        delegate.activity.handle(.screenLocked)
        power.apply(Self.snapshot(source: .wall), now: 200)
        #expect(events.isEmpty)

        delegate.activity.handle(.screenUnlocked)
        power.apply(Self.snapshot(source: .battery), now: 300)

        #expect(events == [.unplugged(level: 66)])
    }

    private static func snapshot(source: PowerSource) -> PowerSnapshot {
        PowerSnapshot(
            level: 66, source: source, isCharging: false,
            estimateMinutes: 400, isLowPowerMode: false
        )
    }
}
