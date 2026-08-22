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

    private(set) var currentAnchor: Anchor = .pill(.zero)
    private(set) var currentFrame: CGRect = .zero

    /// Retained so they can actually be removed. Discarding the tokens
    /// made `removeObserver` impossible.
    private var observers: [NSObjectProtocol] = []

    public let state = AppState()
    private let onboarding = OnboardingController()

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

        // The funnel. Every accepted state change re-derives the hover
        // tracking rect from the new presentation, so no caller has to
        // remember to. Nothing outside `AppState.transition(to:)` can
        // change the state, so nothing can bypass this.
        state.onTransition = { [weak self] _ in self?.syncTrackingRect() }

        // Seeds `currentAnchor`, `currentFrame`, `state.anchor`, the panel
        // frame and the tracking rect -- the same five assignments
        // repositioning needs, so they live in one place.
        reposition(metrics: metrics)
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
            // Opened by an explicit click; only another click closes it.
            break

        case .receiving:
            // A drag is in flight. The drop target has to outlive the
            // cursor leaving the notch or the drop can never land.
            break
        }
    }

    // MARK: - Screen changes

    private func observeScreenChanges() {
        // `queue: .main` guarantees these closures run on the main thread,
        // but their type is `@Sendable`, so the compiler can't see that --
        // `MainActor.assumeIsolated` asserts the guarantee the API already
        // gives us rather than deferring the call to a fresh `Task`, which
        // would change *when* repositioning happens relative to the
        // notification.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, let screen = NSScreen.main else { return }
            MainActor.assumeIsolated { _ = self.reposition(metrics: screen.metrics) }
        })

        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, let screen = NSScreen.main else { return }
            MainActor.assumeIsolated { _ = self.reposition(metrics: screen.metrics) }
        })
    }

    private func removeScreenObservers() {
        for token in observers {
            NotificationCenter.default.removeObserver(token)
            NSWorkspace.shared.notificationCenter.removeObserver(token)
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
        guard anchor != currentAnchor || frame != currentFrame else { return false }

        currentAnchor = anchor
        currentFrame = frame
        state.anchor = anchor
        panel?.setFrame(frame, display: true)
        syncTrackingRect()
        return true
    }
}
