import AppKit
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// Following focus inside the frontmost app (2026-10-27): which app is
/// watched, when, and what a window notification or the second look after a
/// switch does with the panel.
///
/// The watcher is a fake, so nothing here registers with a real app; where
/// focus is comes from the `focusScreenMetrics` seam, which a test moves.
@MainActor
struct FocusWithinAppWiringTests {

    /// A notchless display: landing on it turns the anchor into a pill,
    /// which is how a test sees that the panel moved.
    private static let external = ScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
        safeAreaTopInset: 0, auxiliaryTopLeftWidth: 0, auxiliaryTopRightWidth: 0, menuBarHeight: 24
    )
    private static let chrome: pid_t = 42
    private static let warp: pid_t = 43

    final class FakeWatcher: WindowFocusWatcher {
        var trusted = true
        private(set) var watching: pid_t?
        private(set) var onChange: (@MainActor () -> Void)?
        private(set) var stops = 0
        func watch(pid: pid_t, onChange: @escaping @MainActor () -> Void) -> Bool {
            guard trusted else { return false }
            watching = pid
            self.onChange = onChange
            return true
        }
        func stop() {
            stops += 1
            watching = nil
            onChange = nil
        }
        func fire() { onChange?() }
    }

    final class Focus {
        /// The screen the focused window is on; `nil` is no window.
        var on: ScreenMetrics? = NotchedDelegate.metrics
        var asked = 0
    }

    /// A delegate following focus on the notched built-in display, with the
    /// focused window there too.
    private func make(
        choice: DisplayChoice = .focusedWindow, settle: Duration = .milliseconds(5)
    ) -> (AppDelegate, FakeWatcher, Focus) {
        let d = NotchedDelegate.make()
        let watcher = FakeWatcher()
        let focus = Focus()
        d.windowFocusWatcher = watcher
        d.focusSettleDelay = settle
        d.screenMetrics = { _ in NotchedDelegate.metrics }
        d.focusScreenMetrics = { choice in
            guard choice.followsActivation else { return nil }
            focus.asked += 1
            return focus.on
        }
        if choice != .focusedWindow { d.state.onSetDisplayChoice?(choice) }
        return (d, watcher, focus)
    }

    // MARK: - Which app is watched

    /// Following focus, the app that comes forward is the one watched.
    @Test func anAppSwitchWatchesThatApp() {
        let (d, watcher, _) = make()
        d.activeApplicationDidChange(pid: Self.chrome)
        #expect(watcher.watching == Self.chrome)
        d.activeApplicationDidChange(pid: Self.warp)
        #expect(watcher.watching == Self.warp)
    }

    /// This app in front -- Settings -- has no window of anyone else's to
    /// follow, so nothing is watched.
    @Test func thisAppInFrontWatchesNothing() {
        let (d, watcher, _) = make()
        d.activeApplicationDidChange(pid: Self.chrome)
        d.activeApplicationDidChange(pid: ProcessInfo.processInfo.processIdentifier)
        #expect(watcher.watching == nil)
    }

    /// Pinned, nothing is watched; following again watches the app in front
    /// at once, not at the next switch.
    @Test func pinningStopsTheWatchAndFollowingResumesIt() {
        let (d, watcher, _) = make()
        d.activeApplicationDidChange(pid: Self.chrome)
        d.state.onSetDisplayChoice?(.builtIn)
        #expect(watcher.watching == nil)
        d.activeApplicationDidChange(pid: Self.warp)
        #expect(watcher.watching == nil)
        d.state.onSetDisplayChoice?(.focusedWindow)
        #expect(watcher.watching == Self.warp)
    }

    /// The app in front at launch has not come forward, so the launch names
    /// it -- unless it is this app.
    @Test func theLaunchWatchesTheAppInFront() {
        let (d, watcher, _) = make()
        d.frontmostApplicationPID = { Self.chrome }
        d.observeScreenChanges()
        defer { d.applicationWillTerminate(Notification(name: .init("terminate"))) }
        #expect(watcher.watching == Self.chrome)
    }

    @Test func theLaunchWithThisAppInFrontWatchesNothing() {
        let (d, watcher, _) = make()
        d.frontmostApplicationPID = { ProcessInfo.processInfo.processIdentifier }
        d.observeScreenChanges()
        defer { d.applicationWillTerminate(Notification(name: .init("terminate"))) }
        #expect(watcher.watching == nil)
    }

    /// Quitting stops the watch.
    @Test func terminatingStopsTheWatch() {
        let (d, watcher, _) = make()
        d.activeApplicationDidChange(pid: Self.chrome)
        d.applicationWillTerminate(Notification(name: .init("terminate")))
        #expect(watcher.watching == nil)
    }

    // MARK: - What a notification does

    /// The reported case: Chrome in front, and focus moves to its window on
    /// another display -- clicked, ⌘`, or that window dragged there. The
    /// panel goes with it, with no app switch.
    @Test func focusMovingWithinTheAppMovesThePanel() async {
        let (d, watcher, focus) = make()
        d.activeApplicationDidChange(pid: Self.chrome)
        await d.focusSettleTask?.value
        #expect(d.currentAnchor.isNotch)

        focus.on = Self.external
        watcher.fire()
        #expect(d.currentAnchor.isNotch == false)
    }

    /// A drag posts a notification many times a second: read once at the
    /// first, then once more when the wait has passed, not once each.
    @Test func aBurstOfNotificationsIsReadTwice() async {
        let (d, watcher, focus) = make()
        d.activeApplicationDidChange(pid: Self.chrome)
        await d.focusSettleTask?.value
        focus.asked = 0

        for _ in 0..<10 { watcher.fire() }
        #expect(focus.asked == 1)
        await d.focusSettleTask?.value
        #expect(focus.asked == 2)
    }

    /// The last of a drag is where the window ended up: the second look
    /// places the panel there.
    @Test func theSecondLookFindsWhereTheDragEnded() async {
        let (d, watcher, focus) = make()
        d.activeApplicationDidChange(pid: Self.chrome)
        await d.focusSettleTask?.value

        watcher.fire()
        focus.on = Self.external
        watcher.fire()
        #expect(d.currentAnchor.isNotch)
        await d.focusSettleTask?.value
        #expect(d.currentAnchor.isNotch == false)
    }

    /// Pinned, a notification that was already on its way moves nothing.
    @Test func pinnedANotificationMovesNothing() {
        let (d, watcher, focus) = make()
        d.activeApplicationDidChange(pid: Self.chrome)
        let late = watcher.onChange
        d.state.onSetDisplayChoice?(.builtIn)
        focus.on = Self.external
        late?()
        #expect(d.currentAnchor.isNotch)
        #expect(d.focusSettleTask == nil)
    }

    // MARK: - The second look after a switch

    /// The unconfirmed miss: an app brought forward by a click on its window
    /// on another display, announced before that window is raised. The first
    /// read finds the old window; the second, after the wait, the clicked
    /// one.
    @Test func theSecondLookAfterASwitchFindsALateRaise() async {
        let (d, _, focus) = make()
        d.activeApplicationDidChange(pid: Self.chrome)
        #expect(d.currentAnchor.isNotch)

        focus.on = Self.external
        await d.focusSettleTask?.value
        #expect(d.currentAnchor.isNotch == false)
    }

    /// A Space change looks twice too.
    @Test func aSpaceChangeLooksAgainAfterTheWait() async {
        let (d, _, focus) = make()
        d.activeSpaceDidChange()
        focus.on = Self.external
        await d.focusSettleTask?.value
        #expect(d.currentAnchor.isNotch == false)
    }

    /// Another switch during the wait starts it again, so the second look
    /// comes after the last switch rather than the first.
    @Test func anotherSwitchRestartsTheWait() async {
        let (d, _, _) = make(settle: .seconds(60))
        d.activeApplicationDidChange(pid: Self.chrome)
        let first = d.focusSettleTask
        d.activeApplicationDidChange(pid: Self.warp)
        #expect(first != nil)
        #expect(d.focusSettleTask != first)
        #expect(first?.isCancelled == true)
        d.applicationWillTerminate(Notification(name: .init("terminate")))
    }

    /// Pinned, a switch schedules no second look; pinning cancels one due.
    @Test func pinnedNoSecondLook() {
        let (d, _, _) = make(settle: .seconds(60))
        d.activeApplicationDidChange(pid: Self.chrome)
        let due = d.focusSettleTask
        d.state.onSetDisplayChoice?(.builtIn)
        #expect(due?.isCancelled == true)
        d.activeApplicationDidChange(pid: Self.warp)
        d.activeSpaceDidChange()
        #expect(d.focusSettleTask == nil)
    }

    /// Quitting cancels a look still due.
    @Test func terminatingCancelsTheSecondLook() {
        let (d, _, _) = make(settle: .seconds(60))
        d.activeApplicationDidChange(pid: Self.chrome)
        let due = d.focusSettleTask
        d.applicationWillTerminate(Notification(name: .init("terminate")))
        #expect(due?.isCancelled == true)
        #expect(d.focusSettleTask == nil)
    }
}
