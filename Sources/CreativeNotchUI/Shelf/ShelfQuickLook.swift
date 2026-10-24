import AppKit
import QuickLookUI
import CreativeNotchCore

/// What the delegate needs from a file preview, so a test can stand in for
/// Quick Look without a panel appearing on the machine running it.
@MainActor
protocol ShelfPreviewing: AnyObject {
    /// Whether a preview is on screen now. Space toggles on it.
    var isVisible: Bool { get }
    /// Only the real Quick Look says so — the sandbox check
    /// (`SandboxedSeamsTests`) reads it as a value, like `ShelfTrash.isSystem`.
    var isSystem: Bool { get }
    func show(_ request: ShelfPreviewRequest)
    func close()
    /// Called once the preview has closed itself — Quick Look's own Space,
    /// Esc or close button — so the keyboard it held can be handed back.
    /// Not called for `close()`: whoever asked already knows.
    var onClose: (@MainActor () -> Void)? { get set }
}

/// A bare delegate's preview: shows nothing. Only `configureForRealLaunch()`
/// hands in `ShelfQuickLook`.
@MainActor
final class InertShelfPreview: ShelfPreviewing {
    var isVisible: Bool { false }
    var isSystem: Bool { false }
    var onClose: (@MainActor () -> Void)?
    func show(_ request: ShelfPreviewRequest) {}
    func close() {}
}

/// Opens a shelf file with its default app, or doesn't: the sandboxed
/// default answers `false` and touches nothing, so a test can never launch
/// Preview or TextEdit on the developer's machine.
struct ShelfOpener {
    let isSystem: Bool
    let open: @MainActor (URL) -> Bool

    init(isSystem: Bool, open: @escaping @MainActor (URL) -> Bool) {
        self.isSystem = isSystem
        self.open = open
    }

    /// `NSWorkspace.open`, which hands the file to whatever app the user has
    /// chosen for its type — the same as a double-click in Finder. A file
    /// gone from underneath the shelf is not offered: the system would only
    /// answer with an error dialog of its own.
    static let system = ShelfOpener(isSystem: true) { url in
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        return NSWorkspace.shared.open(url)
    }

    static let inert = ShelfOpener(isSystem: false) { _ in false }
}

/// Quick Look for the shelf (2026-10-24): the system's own preview panel,
/// the one Space opens in Finder.
///
/// **Nothing runs until it is asked.** No panel is created to answer
/// `isVisible` or `close` — `sharedPreviewPanelExists()` is checked first —
/// so a shelf nobody previews never makes one, and there is no observer or
/// timer: Quick Look draws, pages and closes itself.
///
/// **The data source is set directly and through the responder chain.**
/// `QLPreviewPanel` looks for its controller by walking the key window's
/// responder chain, and the notch panel answers there (`NotchPanel`'s
/// `acceptsPreviewPanelControl`). But the notch panel is non-activating and
/// is not key on a hover-open, and once the preview itself is key the chain
/// it walks is its own — so the controller is also handed over before the
/// panel is ordered front, and the walk finding it again is harmless.
///
/// **The preview takes the keyboard** (`prepare`), so it answers its own
/// keys as in Finder. The request holds every ready shelf item, so Quick
/// Look's arrows and arrow keys page along the shelf; a file still copying
/// in is not in it. Paging moves the preview, not the shelf's selection
/// ring, which stays on the tile the preview was opened from.
@MainActor
final class ShelfQuickLook: NSObject, ShelfPreviewing {
    private(set) var request: ShelfPreviewRequest?

    var isSystem: Bool { true }

    var onClose: (@MainActor () -> Void)?

    var isVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
    }

    /// Takes `request` as what the panel will read, without showing it.
    /// Separate from `show` so the data source is testable with no panel.
    func load(_ request: ShelfPreviewRequest) {
        self.request = request
    }

    func show(_ request: ShelfPreviewRequest) {
        load(request)
        guard let panel = QLPreviewPanel.shared() else { return }
        observeClosing(of: panel)
        attach(to: panel)
        panel.reloadData()
        panel.currentPreviewItemIndex = request.index
        if !panel.isVisible {
            Self.prepare(panel)
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// The level a preview needs: above the notch panel's own, or a preview
    /// opened from it would draw underneath the panel that asked for it.
    static let previewLevel = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)

    /// Readies Quick Look's panel to take the keyboard from an app that is
    /// never frontmost (2026-10-24).
    ///
    /// CreativeNotch is an accessory app whose key window, the notch panel,
    /// is non-activating: it holds the keyboard while another app stays
    /// frontmost. `QLPreviewPanel` is an ordinary panel, and an ordinary
    /// panel cannot become key in an app that is not active — so
    /// `makeKeyAndOrderFront` used to leave *no* window of ours key, the
    /// notch panel having resigned, and the next Space typed a space into
    /// whatever document was frontmost. Made non-activating too, the
    /// preview becomes key the way the notch panel does: Quick Look's own
    /// Space and Esc close it, its arrows page the shelf, and on closing the
    /// keyboard is handed back to the notch panel (`observeClosing`), so
    /// Space there previews again.
    /// Checked against the window server with the opt-in live suite
    /// (`ShelfQuickLookLive`); a headless suite cannot see key focus.
    ///
    /// Takes any `NSPanel` so the settings are testable without asking for
    /// the shared preview panel.
    static func prepare(_ panel: NSPanel) {
        panel.level = max(panel.level, previewLevel)
        panel.styleMask.insert(.nonactivatingPanel)
    }

    /// Quick Look closing on its own Space, Esc or close button. The
    /// keyboard it held does not fall back to the notch panel by itself — in
    /// an app that is never active nothing is key afterwards, and the next
    /// Space would go to the frontmost app — so `onClose` hands it back.
    ///
    /// A notification rather than the panel's window delegate: Quick Look
    /// ends the controller's tenure (`endPreviewPanelControl`, which clears
    /// the delegate) before the window closes, so a delegate never hears it.
    /// Observed from the first `show` on, never before, so a shelf nobody
    /// previews has no observer; one observer for the app's life, as the
    /// shared panel is.
    private var closeObserver: NSObjectProtocol?

    private func observeClosing(of panel: QLPreviewPanel) {
        guard closeObserver == nil else { return }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: panel, queue: nil
        ) { [weak self] _ in
            // On the next turn of the run loop, once the panel is really
            // gone: made key now, the notch panel would lose it again to the
            // window closing. In the common modes, so it runs even while
            // a menu or a drag is tracking.
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated { self?.onClose?() }
            }
        }
    }

    func close() {
        guard QLPreviewPanel.sharedPreviewPanelExists(),
              let panel = QLPreviewPanel.shared(), panel.isVisible else { return }
        panel.orderOut(nil)
    }

    /// Becomes the panel's controller. Called from `show` and from the
    /// responder chain's `beginPreviewPanelControl`.
    func attach(to panel: QLPreviewPanel) {
        panel.dataSource = self
        panel.delegate = self
    }

    /// Lets go of the panel, from `endPreviewPanelControl`. Only if this is
    /// still the controller: another app's Quick Look is none of ours.
    func detach(from panel: QLPreviewPanel) {
        if panel.dataSource === self { panel.dataSource = nil }
        if panel.delegate === self { panel.delegate = nil }
    }
}

/// Quick Look reads its data source on the main thread, like every panel
/// callback; the protocols are just not annotated.
extension ShelfQuickLook: QLPreviewPanelDataSource {
    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { request?.urls.count ?? 0 }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let url: URL? = MainActor.assumeIsolated {
            guard let urls = request?.urls, urls.indices.contains(index) else { return nil }
            return urls[index]
        }
        return url.map { $0 as NSURL }
    }
}

extension ShelfQuickLook: QLPreviewPanelDelegate {}
