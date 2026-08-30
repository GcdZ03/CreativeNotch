import AppKit
import CreativeNotchCore

/// Observer, gate and arming in one place — the module's only stateful
/// object, and the only thing that can see a *transition*.
///
/// `PowerObserver` reports what is true now. Only something holding the
/// previous snapshot can say the charger just moved, which is why that one
/// piece of state lives here rather than in either pure type.
///
/// Shaped after `HUDController` and `ClipboardController`: built in
/// `AppDelegate.install`, started and stopped from the app lifecycle,
/// gated by `setActivity`.
@MainActor
public final class PowerController {

    /// Something worth interrupting for.
    public var onEvent: ((PowerEvent) -> Void)?

    /// Current truth for the panel.
    public var onSnapshot: ((PowerSnapshot) -> Void)?

    public var hasBattery: Bool { observer.hasBattery }

    private let observer = PowerObserver()
    private var arming = LowBatteryArming()
    private var previous: PowerSnapshot?
    private var activity: SystemActivity = .active

    public init() {
        observer.onChange = { [weak self] snapshot in
            // `[weak self]`: the observer holds this closure, and a strong
            // capture would be a component keeping its owner alive — the
            // same reason `media.onChange` in `AppDelegate` is weak.
            self?.apply(snapshot)
        }
    }

    public func start() { observer.start() }
    public func stop() { observer.stop() }

    /// Whether the observer is registered.
    ///
    /// Internal, for the lifecycle proof — the same reason
    /// `PowerObserver.registrationCount` is.
    var isObserving: Bool { observer.registrationCount > 0 }

    /// The lock and sleep gate, fanned out from `AppDelegate`.
    ///
    /// Note what this does *not* do: it does not stop the observer. A
    /// registered run-loop source that never fires costs nothing, and
    /// suspending it would mean missing the charger being plugged in while
    /// the lid is shut — the state would then be wrong on wake, which is
    /// worse than an unseen callback.
    public func setActivity(_ next: SystemActivity) {
        activity = next
    }

    /// The whole decision path, from one snapshot.
    ///
    /// Internal so the entire module can be driven by a test without
    /// IOKit or a charger being moved by hand. It takes no clock: with the
    /// time-remaining estimate gone, nothing here is time-dependent.
    func apply(_ snapshot: PowerSnapshot) {
        defer { previous = snapshot }

        let sourceChanged = previous.map { $0.source != snapshot.source } ?? false

        onSnapshot?(snapshot)

        // Arming is advanced whatever the activity, so a threshold
        // genuinely crossed behind a lock screen is spent rather than
        // waiting to ambush the user on unlock.
        let crossed = arming.crossing(
            level: snapshot.level,
            isPluggedIn: snapshot.isPluggedIn
        )

        // The first snapshot is a baseline, not an event: launching the app
        // on a plugged-in machine is not the charger being plugged in.
        guard let previous else { return }

        // Peeks only. Everything above this line still runs while locked or
        // asleep — the panel keeps current truth, and the arming stays
        // honest — but nothing is drawn at a screen nobody is looking at.
        guard activity == .active else { return }

        // One slot, so one event. Ordered by what the person most needs to
        // know: the battery is running out, then the machine changed its
        // own behaviour, then the cable moved. macOS enables Low Power Mode
        // automatically at 20%, so the first two genuinely arrive together
        // and this ordering is load-bearing rather than theoretical.
        if let crossed {
            onEvent?(.lowBattery(threshold: crossed, level: snapshot.level))
        } else if previous.isLowPowerMode != snapshot.isLowPowerMode {
            onEvent?(.lowPowerMode(enabled: snapshot.isLowPowerMode))
        } else if sourceChanged {
            onEvent?(
                snapshot.isPluggedIn
                    ? .pluggedIn(level: snapshot.level)
                    : .unplugged(level: snapshot.level)
            )
        }
    }
}
