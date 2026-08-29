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
        delegate.activity.handle(.screenUnlocked)

        #expect(clipboard.poller.scheduledInterval == ClipboardPollSchedule.activeInterval)
    }
}
