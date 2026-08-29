import AppKit
import CreativeNotchCore

/// Owns the clipboard module's moving parts and the wiring between them.
///
/// Shaped after `HUDController`: `ClipboardPoller` and
/// `SystemActivityObserver` are dumb sources, and everything that connects
/// them lives here rather than being spread through `AppDelegate`, where
/// it could not be tested.
@MainActor
public final class ClipboardController {

    public let store: ClipboardStore

    /// Internal rather than private so the lifecycle is provable, the way
    /// `HUDController` exposes its three observers.
    let poller: ClipboardPoller
    let activity = SystemActivityObserver()

    private let pasteboard: NSPasteboard

    public init(store: ClipboardStore, pasteboard: NSPasteboard = .general) {
        self.store = store
        self.pasteboard = pasteboard
        self.poller = ClipboardPoller(pasteboard: pasteboard)
    }

    public func start() {
        poller.onCapture = { [weak self] content in
            self?.store.record(content, now: Date())
        }
        activity.onChange = { [weak self] activity in
            self?.poller.setActivity(activity, now: Date().timeIntervalSince1970)
        }
        activity.start()
        poller.start(now: Date().timeIntervalSince1970)
    }

    public func stop() {
        poller.stop()
        activity.stop()
    }

    /// Puts an entry back on the pasteboard. That is the whole action —
    /// see `NSPasteboard.write(_:)` for why there is no keystroke.
    ///
    /// No attempt is made to hide the resulting change from the poller.
    /// The write bumps `changeCount`, the poller reads it back, and
    /// `ClipboardStore.record` promotes the entry that is already there.
    /// One copy, at the front, which is the right answer — reached without
    /// a suppression rule that would have to stay correct forever.
    public func paste(_ entry: ClipboardEntry) {
        pasteboard.write(entry.content)
    }
}
