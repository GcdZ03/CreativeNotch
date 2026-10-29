import AppKit
import CreativeNotchCore

/// Owns the clipboard module's moving parts and the wiring between them.
///
/// Dumb sources, one owner: `ClipboardPoller` and
/// `SystemActivityObserver` are dumb sources, and everything that connects
/// them lives here rather than being spread through `AppDelegate`, where
/// it could not be tested.
@MainActor
public final class ClipboardController {

    public let store: ClipboardStore

    /// Internal rather than private so the lifecycle is provable, the way
    /// the other controllers expose their own sources.
    let poller: ClipboardPoller

    /// Internal so a test can see which pasteboard the delegate handed in.
    let pasteboard: NSPasteboard

    public init(store: ClipboardStore, pasteboard: NSPasteboard = .general) {
        self.store = store
        self.pasteboard = pasteboard
        self.poller = ClipboardPoller(pasteboard: pasteboard)
    }

    public func start() {
        poller.onCapture = { [weak self] content in
            self?.store.record(content, now: Date())
        }
        poller.start(now: Date().timeIntervalSince1970)
    }

    public func stop() {
        poller.stop()
    }

    /// The activity gate reaches the poller through here rather than
    /// through an observer this type owns. Spec section 4.7 puts the gate
    /// in one place; `AppDelegate` holds it and fans it out, so the media
    /// module and this one cannot disagree about whether the screen is
    /// locked.
    public func setActivity(_ activity: SystemActivity, now: TimeInterval) {
        poller.setActivity(activity, now: now)
    }

    /// Puts an entry back on the pasteboard. That is the whole action —
    /// see `NSPasteboard.write(_:)` for why there is no keystroke. Named
    /// `copy` rather than `paste` for the same reason the row says "Copy":
    /// without Accessibility permission the app cannot paste, and the
    /// verb should not promise what the action does not do.
    ///
    /// No attempt is made to hide the resulting change from the poller.
    /// The write bumps `changeCount`, the poller reads it back, and
    /// `ClipboardStore.record` promotes the entry that is already there.
    /// One copy, at the front, which is the right answer — reached without
    /// a suppression rule that would have to stay correct forever.
    public func copy(_ entry: ClipboardEntry) {
        pasteboard.write(entry.content)
    }
}
