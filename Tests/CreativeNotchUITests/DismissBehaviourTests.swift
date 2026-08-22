import AppKit
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// Dismissing an open panel.
///
/// `hitTest` deliberately returns nil outside the visible shape, so a click
/// anywhere else passes straight through and the app never hears about it.
/// That is what keeps menu bar clicks working — and it is also why closing
/// on an outside click needs an explicit monitor rather than falling out of
/// normal event delivery.
///
/// The monitor is installed only while the panel is open, so nothing runs
/// at idle.
@MainActor
struct DismissBehaviourTests {

    private static let notched = ScreenMetrics(
        frame: CGRect(x: 1470, y: 200, width: 1470, height: 956),
        safeAreaTopInset: 38,
        auxiliaryTopLeftWidth: 620,
        auxiliaryTopRightWidth: 620,
        menuBarHeight: 38
    )

    /// A delegate whose grace period is short enough to await, and whose
    /// outside-click monitor is a spy rather than a real global monitor.
    private func makeDelegate(
        grace: Duration = .milliseconds(20)
    ) -> (AppDelegate, MonitorSpy) {
        let spy = MonitorSpy()
        let delegate = AppDelegate()
        delegate.installOutsideClickMonitor = { handler in spy.install(handler) }
        delegate.removeOutsideClickMonitor = { spy.remove($0) }
        delegate.growthDelay = .zero
        delegate.install(metrics: Self.notched)
        delegate.dismissGrace = grace
        return (delegate, spy)
    }

    final class MonitorSpy {
        private(set) var installs = 0
        private(set) var removals = 0
        private(set) var handler: (() -> Void)?
        var isInstalled: Bool { handler != nil }

        func install(_ handler: @escaping () -> Void) -> Any? {
            installs += 1
            self.handler = handler
            return installs as NSNumber
        }

        func remove(_ token: Any) {
            removals += 1
            handler = nil
        }

        /// Simulate a click landing in another application.
        func click() { handler?() }
    }

    // MARK: - The grace period

    @Test func theShippedGraceIsFourHundredMilliseconds() {
        #expect(AppDelegate.defaultDismissGrace == .milliseconds(400))
        #expect(AppDelegate().dismissGrace == .milliseconds(400))
    }

    @Test func aMouseExitDoesNotCloseTheOpenPanelImmediately() {
        let (delegate, _) = makeDelegate()
        delegate.state.transition(to: .open(.shelf))
        delegate.hoverView?.onExit()
        // Still open: the grace has not elapsed.
        #expect(delegate.state.state == .open(.shelf))
    }

    @Test func aMouseExitClosesTheOpenPanelOnceTheGraceElapses() async throws {
        let (delegate, _) = makeDelegate()
        delegate.state.transition(to: .open(.shelf))
        delegate.hoverView?.onExit()
        try await Task.sleep(for: .milliseconds(120))
        #expect(delegate.state.state == .closed)
    }

    @Test func returningDuringTheGraceKeepsThePanelOpen() async throws {
        let (delegate, _) = makeDelegate()
        delegate.state.transition(to: .open(.shelf))
        delegate.hoverView?.onExit()
        delegate.hoverView?.onEnter()          // cursor came back
        try await Task.sleep(for: .milliseconds(120))
        #expect(delegate.state.state == .open(.shelf))
    }

    /// The grace must not resurrect a panel the user already closed.
    @Test func clickingClosedDuringTheGraceLeavesItClosed() async throws {
        let (delegate, _) = makeDelegate()
        delegate.state.transition(to: .open(.shelf))
        delegate.hoverView?.onExit()
        delegate.state.transition(to: .closed)
        try await Task.sleep(for: .milliseconds(120))
        #expect(delegate.state.state == .closed)
    }

    /// A drag in flight has to outlive the cursor leaving, grace or no
    /// grace, or the drop can never land.
    @Test func aDragInFlightIsNeverDismissedByLeaving() async throws {
        let (delegate, _) = makeDelegate()
        delegate.state.transition(to: .receiving)
        delegate.hoverView?.onExit()
        try await Task.sleep(for: .milliseconds(120))
        #expect(delegate.state.state == .receiving)
    }

    // MARK: - The outside-click monitor

    @Test func noMonitorRunsWhileTheNotchIsIdle() {
        let (_, spy) = makeDelegate()
        #expect(spy.isInstalled == false)
        #expect(spy.installs == 0)
    }

    @Test func aPeekDoesNotInstallTheMonitor() {
        let (delegate, spy) = makeDelegate()
        delegate.state.transition(to: .peek(.dragTarget))
        #expect(spy.isInstalled == false)
    }

    @Test func openingInstallsTheMonitorAndClosingRemovesIt() {
        let (delegate, spy) = makeDelegate()
        delegate.state.transition(to: .open(.shelf))
        #expect(spy.isInstalled)
        #expect(spy.installs == 1)

        delegate.state.transition(to: .closed)
        #expect(spy.isInstalled == false)
        #expect(spy.removals == 1)
    }

    @Test func switchingTabsDoesNotReinstallTheMonitor() {
        let (delegate, spy) = makeDelegate()
        delegate.state.transition(to: .open(.shelf))
        delegate.state.transition(to: .open(.clipboard))
        #expect(spy.installs == 1)
        #expect(spy.removals == 0)
    }

    @Test func anOutsideClickClosesTheOpenPanel() {
        let (delegate, spy) = makeDelegate()
        delegate.state.transition(to: .open(.shelf))
        spy.click()
        #expect(delegate.state.state == .closed)
        #expect(spy.isInstalled == false)
    }

    // MARK: - App switching

    @Test func activatingAnotherAppClosesTheOpenPanel() {
        let (delegate, _) = makeDelegate()
        delegate.state.transition(to: .open(.shelf))
        delegate.applicationDidActivate(pid: -1)   // never our own pid
        #expect(delegate.state.state == .closed)
    }

    @Test func activatingOurselfLeavesThePanelOpen() {
        let (delegate, _) = makeDelegate()
        delegate.state.transition(to: .open(.shelf))
        delegate.applicationDidActivate(pid: ProcessInfo.processInfo.processIdentifier)
        #expect(delegate.state.state == .open(.shelf))
    }

    @Test func activatingAnotherAppDoesNotDisturbADrag() {
        let (delegate, _) = makeDelegate()
        delegate.state.transition(to: .receiving)
        delegate.applicationDidActivate(pid: -1)
        #expect(delegate.state.state == .receiving)
    }
}
