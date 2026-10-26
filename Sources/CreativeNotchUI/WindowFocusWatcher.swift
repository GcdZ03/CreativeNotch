import AppKit
import ApplicationServices

/// Hears focus move inside the frontmost app, for "Show on: the focused
/// window" (2026-10-27).
///
/// Clicking or ⌘` between two windows of one app on different displays is no
/// app switch and no Space change, and a window dragged or scripted onto
/// another display is neither either -- so the notch stayed behind. Only
/// Accessibility reports them, as notifications from the app itself: nothing
/// runs between them, which is why this is not the global click monitor
/// CONTRIBUTING declines. It needs the access "Keep clear of app menus" asks
/// for, and never asks itself: without it, nothing is watched.
///
/// A seam like `AppMenuReader`: the delegate holds a sandbox that never
/// watches, so no test registers with a real app; only
/// `configureForRealLaunch()` hands it `SystemWindowFocusWatcher`.
@MainActor
protocol WindowFocusWatcher: AnyObject {
    /// Watches `pid`'s windows, calling `onChange` when another of them takes
    /// focus or one of them moves, in place of any earlier watch. Returns
    /// whether it is watching: not without Accessibility access, or when the
    /// app would not take the registration.
    @discardableResult
    func watch(pid: pid_t, onChange: @escaping @MainActor () -> Void) -> Bool
    /// Stops watching, if it was.
    func stop()
}

/// The default: never watches.
final class SandboxWindowFocusWatcher: WindowFocusWatcher {
    func watch(pid: pid_t, onChange: @escaping @MainActor () -> Void) -> Bool { false }
    func stop() {}
}

/// The real watcher: an `AXObserver` on the frontmost app, its source on the
/// main run loop.
///
/// Measured 2026-10-27 against Chrome: another of its windows coming forward
/// -- clicked, or raised by script as ⌘` does -- posts
/// `AXFocusedWindowChanged` within a few milliseconds, and a window moved by
/// script or dragged posts `AXWindowMoved`, both on the application element,
/// so one registration covers every window the app has or opens. A resize is
/// not watched: it rarely carries a window to another display.
final class SystemWindowFocusWatcher: WindowFocusWatcher {
    private static let notifications = [kAXFocusedWindowChangedNotification, kAXWindowMovedNotification]

    private var observer: AXObserver?
    private var watchedPID: pid_t?
    private var onChange: (@MainActor () -> Void)?

    init() {
        // Registering messages the app, on the main thread: the same bound
        // as reading its menus, so an app hanging as it comes forward cannot
        // hang the notch with it.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), SystemAppMenuReader.messagingTimeout)
    }

    func watch(pid: pid_t, onChange: @escaping @MainActor () -> Void) -> Bool {
        if pid == watchedPID, observer != nil {
            self.onChange = onChange
            return true
        }
        stop()
        guard AXIsProcessTrusted() else { return false }
        var created: AXObserver?
        guard AXObserverCreate(pid, Self.callback, &created) == .success, let created else { return false }
        let app = AXUIElementCreateApplication(pid)
        // Unretained: the observer is removed in `stop()`, and the delegate
        // holds this watcher for the life of the app.
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let added = Self.notifications.filter {
            AXObserverAddNotification(created, app, $0 as CFString, refcon) == .success
        }
        guard !added.isEmpty else { return false }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        observer = created
        watchedPID = pid
        self.onChange = onChange
        return true
    }

    func stop() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        watchedPID = nil
        onChange = nil
    }

    /// Delivered on the main run loop, where the source was added.
    private static let callback: AXObserverCallback = { _, _, _, refcon in
        guard let refcon else { return }
        let watcher = Unmanaged<SystemWindowFocusWatcher>.fromOpaque(refcon).takeUnretainedValue()
        MainActor.assumeIsolated { watcher.onChange?() }
    }
}
