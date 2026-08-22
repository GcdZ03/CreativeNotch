import AppKit
import SwiftUI
import CreativeNotchCore

@main
struct CreativeNotchApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // no Dock icon
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NotchPanel?
    private var hostView: HitTestingHostingView<NotchRootView>?
    let state = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.main else { return }
        install(on: screen)
    }

    private func install(on screen: NSScreen) {
        let metrics = screen.metrics
        let anchor = NotchGeometry.anchor(for: metrics)
        let frame = NotchGeometry.panelFrame(for: anchor, in: metrics)

        state.anchor = anchor

        let panel = NotchPanel(contentRect: frame)
        let host = HitTestingHostingView(rootView: NotchRootView(app: state))
        host.visibleRectProvider = { [weak self] in
            guard let self else { return .zero }
            return NotchShape.visibleRect(
                presentation: self.state.state.presentation,
                anchor: anchor,
                panelFrame: frame
            )
        }

        panel.contentView = host
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()

        self.panel = panel
        self.hostView = host
    }
}
