import AppKit
import CreativeNotchCore

/// Owns the panel, its views, and the app-lifetime observers.
///
/// Lives in `CreativeNotchUI` rather than the executable target because
/// SwiftPM cannot link an executable into a test target: while this class
/// sat in `Sources/CreativeNotch` it -- and therefore the whole
/// state/tracking-rect/repositioning core of the app -- was unreachable
/// by any test. The executable is now a five-line launcher.
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {

    private(set) var panel: NotchPanel?
    private var hostView: HitTestingHostingView<NotchRootView>?
    private(set) var hoverView: HoverTracker?
    private var menuBar: MenuBarController?

    /// Views onto the funnel rather than a second copy. They used to be
    /// stored here *and* on `AppState`, which is two places one value can
    /// drift apart. (Follow-up F4.)
    var currentAnchor: Anchor { state.anchor }
    var currentFrame: CGRect { state.panelFrame }

    /// Each token paired with the centre that issued it. Passing every
    /// token to both centres worked only because the mismatched calls are
    /// no-ops. (Follow-up F3.)
    private var observers: [(token: NSObjectProtocol, center: NotificationCenter)] = []

    /// Removed and re-registered by `install`, so building the panel twice
    /// cannot stack duplicate observers on the state.
    private var stateObserver: AppState.ObserverToken?

    /// The centre each screen observer was registered with, so the pairing
    /// that F3 fixed is assertable. Removing a token from the wrong centre
    /// is a silent no-op, which is exactly why it went unnoticed.
    var screenObserverCenters: [NotificationCenter] { observers.map(\.center) }

    var stateObserverCount: Int { state.observerCount }

    public let state = AppState()
    private let onboarding = OnboardingController()

    // MARK: - Dismissal

    /// How long an open panel survives the cursor leaving it.
    ///
    /// Without a grace period, brushing a pixel past the edge snaps the
    /// panel shut, which reads as a glitch rather than as intent. The
    /// mirror image of the 300ms hover dwell.
    public static let defaultDismissGrace: Duration = .milliseconds(400)

    /// Overridable so tests can await it instead of waiting 400ms each.
    var dismissGrace: Duration = AppDelegate.defaultDismissGrace

    private var graceTask: Task<Void, Never>?

    /// Installs a monitor calling `handler` when a mouse-down lands in
    /// another application; returns a token for removal.
    ///
    /// Injected rather than called directly so the install/remove
    /// lifecycle is assertable without a real global monitor -- and so a
    /// test can fire a synthetic outside click.
    var installOutsideClickMonitor: (@escaping () -> Void) -> Any? = { handler in
        NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { _ in handler() }
    }

    var removeOutsideClickMonitor: (Any) -> Void = { NSEvent.removeMonitor($0) }

    private var outsideClickToken: Any?

    /// Whether the outside-click monitor is currently installed. Nothing
    /// should be running while the notch is idle.
    var isWatchingForOutsideClicks: Bool { outsideClickToken != nil }

    public override init() { super.init() }

    // MARK: - Lifecycle

    public func applicationDidFinishLaunching(_ notification: Notification) {
        if let screen = NSScreen.main {
            install(metrics: screen.metrics)
            // Presentation is deliberately *not* part of `install` -- that
            // keeps the wiring path testable without putting a window on
            // screen.
            panel?.orderFrontRegardless()
        }

        let menuBar = MenuBarController { [weak self] in
            self?.showOnboarding()
        }
        menuBar.install()
        self.menuBar = menuBar

        // Observing is a lifecycle concern, not part of building the
        // panel: registering it from inside `install` meant it could be
        // registered more than once and never at a point where the tokens
        // had an owner.
        observeScreenChanges()

        onboarding.showIfNeeded()
    }

    public func applicationWillTerminate(_ notification: Notification) {
        removeScreenObservers()
    }

    public func showOnboarding() {
        onboarding.show()
    }

    // MARK: - Installation

    /// Builds the panel, the SwiftUI host, and the hover tracker, wires
    /// the state funnel, and positions everything for `metrics`.
    ///
    /// Takes `ScreenMetrics` rather than an `NSScreen` so the whole path
    /// is drivable from a test with no real display attached.
    func install(metrics: ScreenMetrics) {
        let size = NotchGeometry
            .panelFrame(for: NotchGeometry.anchor(for: metrics), in: metrics)
            .size

        let panel = NotchPanel(contentRect: CGRect(origin: .zero, size: size))

        let host = HitTestingHostingView(rootView: NotchRootView(app: state))
        host.visibleRectProvider = { [weak self] in self?.visibleRect() ?? .zero }

        let hover = HoverTracker(frame: CGRect(origin: .zero, size: size))
        hover.autoresizingMask = [.width, .height]
        hover.onEnter = { [weak self] in self?.cancelDismissGrace() }
        hover.onDwell = { [weak self] in self?.peek() }
        hover.onExit  = { [weak self] in self?.collapse() }

        let container = NSView(frame: CGRect(origin: .zero, size: size))
        container.addSubview(host)
        container.addSubview(hover)
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]

        panel.contentView = container

        self.panel = panel
        self.hostView = host
        self.hoverView = hover

        // The funnel. Every accepted change re-derives the hover tracking
        // rect, so no caller has to remember to. Nothing outside
        // `AppState` can change state or geometry, so nothing bypasses it.
        if let previous = stateObserver { state.removeObserver(previous) }
        stateObserver = state.observe { [weak self] change in
            guard let self else { return }
            self.syncTrackingRect()
            if case .state(let newState) = change {
                self.syncDismissAffordances(for: newState)
            }
        }

        // Seeding is unconditional on purpose. `reposition` dedupes on the
        // geometry being unchanged, which is right for a screen change and
        // wrong here: a second `install` builds a *fresh* panel and hover
        // tracker whose frame and tracking rect are still zero, so
        // delegating to the deduping path left the new panel unpositioned
        // and the tracking rect empty -- no tracking area at all, and hover
        // silently dead. (Follow-up F1.)
        let anchor = NotchGeometry.anchor(for: metrics)
        let frame = NotchGeometry.panelFrame(for: anchor, in: metrics)
        state.setGeometry(anchor: anchor, panelFrame: frame)
        panel.setFrame(frame, display: true)
        syncTrackingRect()
    }

    // MARK: - Derived geometry

    /// The currently-drawn region, panel-local. Both the hit test and the
    /// hover tracking rect read it, so there is exactly one derivation.
    private func visibleRect() -> CGRect {
        NotchShape.visibleRect(
            presentation: state.state.presentation,
            anchor: currentAnchor,
            panelFrame: currentFrame
        )
    }

    private func syncTrackingRect() {
        hoverView?.updateTrackingRect(visibleRect())
    }

    // MARK: - Hover

    private func peek() {
        guard state.state == .closed else { return }
        state.transition(to: .peek(.nowPlaying(
            TrackSnapshot(title: "CreativeNotch", artist: "", isPlaying: true)
        )))
    }

    /// The cursor left the visible shape.
    ///
    /// Every case is named on purpose. The previous form was a
    /// `guard case .open = state else { close }` with an empty success
    /// body, which meant "close" was the default for every state that was
    /// not `.open` -- including states hover has no business ending. Under
    /// that default a drag that moved below the notch closed the drop
    /// target it was aimed at.
    private func collapse() {
        switch state.state {
        case .closed:
            break                       // nothing to collapse

        case .peek:
            // Hover opened it, so hover closes it.
            state.transition(to: .closed)

        case .open:
            // A click opened it, so a click, an app switch, or the cursor
            // staying away closes it. Leaving starts a grace period rather
            // than dismissing outright.
            startDismissGrace()

        case .receiving:
            // A drag is in flight. The drop target has to outlive the
            // cursor leaving the notch or the drop can never land.
            break
        }
    }

    // MARK: - Dismissing an open panel

    /// Keeps the outside-click monitor's lifetime tied to `.open`.
    ///
    /// Driven from the funnel rather than from call sites: every state
    /// change routes through `AppState.transition(to:)`, so there is no
    /// path that can open the panel without arming this, or close it and
    /// leave a monitor running.
    private func syncDismissAffordances(for newState: NotchState) {
        guard case .open = newState else {
            cancelDismissGrace()
            if let token = outsideClickToken {
                removeOutsideClickMonitor(token)
                outsideClickToken = nil
            }
            return
        }

        // Already armed -- switching tabs must not stack monitors.
        guard outsideClickToken == nil else { return }

        outsideClickToken = installOutsideClickMonitor { [weak self] in
            // Global monitor handlers are delivered on the main thread;
            // the closure's type just cannot express that.
            MainActor.assumeIsolated { self?.dismissIfOpen() }
        }
    }

    private func startDismissGrace() {
        graceTask?.cancel()
        graceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.dismissGrace)
            guard !Task.isCancelled else { return }
            self.dismissIfOpen()
        }
    }

    private func cancelDismissGrace() {
        graceTask?.cancel()
        graceTask = nil
    }

    /// Closes the panel only if it is still open, so a pending grace
    /// timer can never reopen or disturb a state the user has since
    /// changed -- a drag in flight above all.
    private func dismissIfOpen() {
        guard case .open = state.state else { return }
        state.transition(to: .closed)
    }

    /// Another application came forward.
    ///
    /// Takes a pid rather than an `NSRunningApplication` so it is drivable
    /// from a test without conjuring a real running app.
    func applicationDidActivate(pid: pid_t) {
        guard pid != ProcessInfo.processInfo.processIdentifier else { return }
        dismissIfOpen()
    }

    // MARK: - Screen changes

    func observeScreenChanges() {
        // `queue: .main` guarantees these closures run on the main thread,
        // but their type is `@Sendable`, so the compiler can't see that --
        // `MainActor.assumeIsolated` asserts the guarantee the API already
        // gives us rather than deferring the call to a fresh `Task`, which
        // would change *when* repositioning happens relative to the
        // notification.
        observers.append((NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, let screen = NSScreen.main else { return }
            MainActor.assumeIsolated { _ = self.reposition(metrics: screen.metrics) }
        }, NotificationCenter.default))

        observers.append((NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            MainActor.assumeIsolated {
                if let pid = app?.processIdentifier {
                    self.applicationDidActivate(pid: pid)
                }
                if let screen = NSScreen.main {
                    _ = self.reposition(metrics: screen.metrics)
                }
            }
        }, NSWorkspace.shared.notificationCenter))
    }

    private func removeScreenObservers() {
        for observer in observers {
            observer.center.removeObserver(observer.token)
        }
        observers.removeAll()
    }

    /// Moves the panel to wherever the notch or pill is on `metrics`.
    ///
    /// Returns whether anything actually moved. `didActivateApplication`
    /// fires on every Cmd-Tab and `@Observable` does not dedupe equal
    /// assignments, so without the guard every app switch pushed a new
    /// frame and a new anchor and forced a redraw -- contradicting the
    /// rule that state transitions are the only thing that triggers one.
    @discardableResult
    func reposition(metrics: ScreenMetrics) -> Bool {
        let anchor = NotchGeometry.anchor(for: metrics)
        let frame = NotchGeometry.panelFrame(for: anchor, in: metrics)
        // The dedupe lives in the funnel now, and the tracking rect
        // re-syncs from the geometry observer.
        guard state.setGeometry(anchor: anchor, panelFrame: frame) else { return false }
        panel?.setFrame(frame, display: true)
        return true
    }
}
