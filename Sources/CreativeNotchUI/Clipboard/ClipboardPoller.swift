import AppKit
import CreativeNotchCore

/// The project's one timer.
///
/// `NSPasteboard` has no change notification, so this module polls — and
/// spec section 5.3 admits exactly one repeating timer to do it. Everything
/// that makes that defensible is enforced here: the `changeCount` guard so
/// almost every tick is a single integer comparison, the back-off from
/// `ClipboardPollSchedule`, and a hard suspension outside `.active`.
///
/// `tick(now:)` carries the whole decision and takes time as a parameter,
/// so the poll path is tested by calling it rather than by sleeping. The
/// timer is injected for the same reason, following the precedent set by
/// `AppDelegate.installOutsideClickMonitor`.
@MainActor
public final class ClipboardPoller {

    public var onCapture: ((ClipboardContent) -> Void)?

    /// Read at each tick rather than observed. It is a free property read
    /// and it cannot drift out of step the way a cached notification value
    /// can.
    public var isLowPowerMode: () -> Bool = {
        ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    /// Injected so tests can assert what was *asked* for without waiting.
    ///
    /// The fire closure is `@MainActor` rather than plain: `Timer`'s block
    /// is `@Sendable`, and under Swift 6 concurrency checking a bare
    /// main-actor closure cannot be sent into one. Global-actor-isolated
    /// closures *are* `Sendable`, so annotating it is what makes the
    /// `assumeIsolated` below legal rather than merely true.
    public var scheduleTimer: (TimeInterval, @escaping @MainActor () -> Void) -> Any? = { interval, fire in
        Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { fire() }
        }
    }

    public var cancelTimer: (Any) -> Void = { ($0 as? Timer)?.invalidate() }

    /// What the running timer is set to, or `nil` when suspended.
    public private(set) var scheduledInterval: TimeInterval?

    private let pasteboard: NSPasteboard
    private var timer: Any?
    private var lastChangeCount: Int
    private var lastChangeAt: TimeInterval = 0
    private var activity: SystemActivity = .active
    private var isRunning = false

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        self.lastChangeCount = pasteboard.changeCount
    }

    /// Adopts whatever is on the pasteboard now as the baseline, without
    /// capturing it. Launching must not sweep in whatever happened to be
    /// copied beforehand.
    ///
    /// Cancels first, the way `SystemActivityObserver.start()` does, so a
    /// second `start` replaces the timer rather than being swallowed by
    /// `reschedule`'s unchanged-interval guard and leaving the old one
    /// running against a fresh baseline.
    public func start(now: TimeInterval) {
        cancelCurrentTimer()
        isRunning = true
        lastChangeCount = pasteboard.changeCount
        lastChangeAt = now
        reschedule(now: now)
    }

    public func stop() {
        isRunning = false
        cancelCurrentTimer()
    }

    /// The gate. Spec section 4.7: no poller runs outside `.active`.
    ///
    /// Resuming **resyncs without capturing**. While suspended, anything
    /// copied moved `changeCount`; adopting that count as the new baseline
    /// without reading the content is the whole point. Capturing it would
    /// mean recording whatever another session or a background process put
    /// on the pasteboard while the screen was locked — the content this
    /// module has the least claim to.
    ///
    /// `lastChangeAt` is reset to the moment of resuming too, so a machine
    /// that slept for a week does not come back polling at the idle rate.
    public func setActivity(_ activity: SystemActivity, now: TimeInterval) {
        guard activity != self.activity else { return }
        self.activity = activity

        guard activity == .active else {
            cancelCurrentTimer()
            return
        }

        lastChangeCount = pasteboard.changeCount
        lastChangeAt = now
        if isRunning { reschedule(now: now) }
    }

    /// One poll.
    ///
    /// The `changeCount` comparison is what makes a 0.75s timer
    /// defensible: on almost every tick it is a single integer comparison
    /// and nothing else. Reading the pasteboard's *contents* every time
    /// would not be.
    ///
    /// Rescheduling happens on every tick, not only on changed ones. The
    /// back-off exists precisely for the case where nothing is changing,
    /// so returning early on an unchanged count would mean the poller
    /// never reached the code that slows it down — and it would sit at
    /// 0.75s forever.
    public func tick(now: TimeInterval) {
        guard isRunning, activity == .active else { return }

        let count = pasteboard.changeCount
        let changed = count != lastChangeCount

        // The clock is advanced before the capture check, not after. A
        // concealed copy is refused, but it is still activity — and the
        // back-off measures time since anything changed. Leaving the clock
        // alone here would have the poller crawling at the idle rate
        // immediately after a password manager copy, which is exactly when
        // the user is busiest.
        if changed {
            lastChangeCount = count
            lastChangeAt = now
        }

        reschedule(now: now)

        guard changed, let content = pasteboard.clipboardCapture() else { return }
        onCapture?(content)
    }

    // MARK: - Internals

    /// Rebuilds the timer only when the wanted interval actually changes.
    /// Rebuilding unconditionally would tear down and recreate a `Timer`
    /// roughly once a second, all day, for no gain.
    private func reschedule(now: TimeInterval) {
        let wanted = ClipboardPollSchedule.interval(
            sinceLastChange: now - lastChangeAt,
            lowPower: isLowPowerMode()
        )
        guard wanted != scheduledInterval else { return }

        cancelCurrentTimer()
        timer = scheduleTimer(wanted) { [weak self] in
            guard let self else { return }
            self.tick(now: Date().timeIntervalSince1970)
        }
        scheduledInterval = wanted
    }

    private func cancelCurrentTimer() {
        if let timer { cancelTimer(timer) }
        timer = nil
        scheduledInterval = nil
    }
}
