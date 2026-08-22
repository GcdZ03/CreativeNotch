import AppKit
import CreativeNotchCore
import CreativeNotchUI

@main
struct CreativeNotchApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // no Dock icon
        // `NSApplication.delegate` is `weak`, and this function has no use of
        // `delegate` after assignment, so ARC has no obligation to keep it
        // alive through `app.run()`'s indefinite runloop without this.
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NotchPanel?
    private var hostView: HitTestingHostingView<NotchRootView>?
    private var hoverView: HoverTracker?
    private var menuBar: MenuBarController?
    private var currentAnchor: Anchor = .pill(.zero)
    private var currentFrame: CGRect = .zero
    let state = AppState()
    private let onboarding = OnboardingController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.main else { return }
        install(on: screen)

        let menuBar = MenuBarController { [weak self] in
            self?.showOnboarding()
        }
        menuBar.install()
        self.menuBar = menuBar

        onboarding.showIfNeeded()
    }

    func showOnboarding() {
        onboarding.show()
    }

    private func install(on screen: NSScreen) {
        let metrics = screen.metrics
        let anchor = NotchGeometry.anchor(for: metrics)
        let frame = NotchGeometry.panelFrame(for: anchor, in: metrics)

        state.anchor = anchor
        currentAnchor = anchor
        currentFrame = frame

        let panel = NotchPanel(contentRect: frame)

        let host = HitTestingHostingView(rootView: NotchRootView(app: state))
        host.visibleRectProvider = { [weak self] in self?.visibleRect() ?? .zero }

        let hover = HoverTracker(frame: CGRect(origin: .zero, size: frame.size))
        hover.autoresizingMask = [.width, .height]
        hover.onDwell = { [weak self] in self?.peek() }
        hover.onExit  = { [weak self] in self?.collapse() }
        hover.updateTrackingRect(visibleRect())

        let container = NSView(frame: CGRect(origin: .zero, size: frame.size))
        container.addSubview(host)
        container.addSubview(hover)
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]

        panel.contentView = container
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()

        self.panel = panel
        self.hostView = host
        self.hoverView = hover

        observeScreenChanges()
    }

    private func visibleRect() -> CGRect {
        NotchShape.visibleRect(
            presentation: state.state.presentation,
            anchor: currentAnchor,
            panelFrame: currentFrame
        )
    }

    private func peek() {
        guard state.state == .closed else { return }
        state.state = .peek(.nowPlaying(
            TrackSnapshot(title: "CreativeNotch", artist: "", isPlaying: true)
        ))
        hoverView?.updateTrackingRect(visibleRect())
    }

    private func collapse() {
        guard case .open = state.state else {
            state.state = .closed
            hoverView?.updateTrackingRect(visibleRect())
            return
        }
    }

    private func observeScreenChanges() {
        // `queue: .main` guarantees these closures run on the main thread,
        // but their type is `@Sendable`, so the compiler can't see that —
        // `MainActor.assumeIsolated` asserts the guarantee the API already
        // gives us rather than deferring the call to a fresh `Task`, which
        // would change *when* repositioning happens relative to the
        // notification.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, let screen = NSScreen.main else { return }
            MainActor.assumeIsolated { self.reposition(on: screen) }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, let screen = NSScreen.main else { return }
            MainActor.assumeIsolated { self.reposition(on: screen) }
        }
    }

    private func reposition(on screen: NSScreen) {
        let metrics = screen.metrics
        let anchor = NotchGeometry.anchor(for: metrics)
        let frame = NotchGeometry.panelFrame(for: anchor, in: metrics)
        currentAnchor = anchor
        currentFrame = frame
        state.anchor = anchor
        panel?.setFrame(frame, display: true)
        hoverView?.updateTrackingRect(visibleRect())
    }
}
