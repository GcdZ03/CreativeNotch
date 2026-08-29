import AppKit
import CreativeNotchCore

/// Turns workspace and distributed notifications into a `SystemActivity`.
///
/// A dumb source, like the HUD's observers: every judgement — including
/// the sleep-outranks-lock precedence that makes waking behind a lock
/// screen safe — lives in `SystemActivityReducer`, in Core, where it runs
/// headlessly.
///
/// Screen lock has no `NSWorkspace` notification. It arrives on
/// `DistributedNotificationCenter` instead, which is why the tokens are
/// stored with the centre they came from: removing a distributed observer
/// from `NSWorkspace.shared.notificationCenter` silently does nothing.
@MainActor
public final class SystemActivityObserver {

    public var onChange: ((SystemActivity) -> Void)?

    public private(set) var activity: SystemActivity = .active

    private var reducer = SystemActivityReducer()
    private var tokens: [(token: NSObjectProtocol, center: NotificationCenter)] = []

    /// Internal rather than private so the lifecycle is provable.
    /// `VolumeObserver`, `BrightnessObserver` and `MediaKeyMonitor` each
    /// shipped a `stop()` that forgot one of the things `start()`
    /// registered, and each was caught by a count like this.
    var tokenCount: Int { tokens.count }

    public init() {}

    public func start() {
        // Re-registering must not stack: `start()` being called twice is a
        // wiring mistake, not a reason to receive every event twice.
        stop()

        let workspace = NSWorkspace.shared.notificationCenter
        observe(NSWorkspace.willSleepNotification, on: workspace, as: .willSleep)
        observe(NSWorkspace.didWakeNotification, on: workspace, as: .didWake)

        let distributed = DistributedNotificationCenter.default()
        observe(Notification.Name("com.apple.screenIsLocked"), on: distributed, as: .screenLocked)
        observe(Notification.Name("com.apple.screenIsUnlocked"), on: distributed, as: .screenUnlocked)
    }

    public func stop() {
        for entry in tokens {
            entry.center.removeObserver(entry.token)
        }
        tokens.removeAll()
    }

    /// Internal so tests can drive the whole path without posting real
    /// system notifications, which cannot be synthesised for lock and
    /// unlock.
    func handle(_ event: SystemActivityEvent) {
        let next = reducer.apply(event)
        // Only changes are reported. `screenIsLocked` can arrive more than
        // once, and the consumer rebuilds a timer on each call — a repeat
        // would restart the poll clock for nothing.
        guard next != activity else { return }
        activity = next
        onChange?(next)
    }

    private func observe(
        _ name: Notification.Name,
        on center: NotificationCenter,
        as event: SystemActivityEvent
    ) {
        // `queue: .main` guarantees these run on the main thread, but the
        // closure type is `@Sendable` so the compiler cannot see it.
        // `assumeIsolated` asserts the guarantee the API already gives
        // rather than deferring to a fresh `Task`, which would change when
        // the suspension happens relative to the notification.
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.handle(event) }
        }
        tokens.append((token, center))
    }
}
