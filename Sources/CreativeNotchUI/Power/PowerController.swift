import AppKit
import CreativeNotchCore

/// Observer, gate and arming in one place — the module's only stateful
/// object, and the only thing that can see a *transition*.
///
/// `PowerObserver` reports what is true now. Only something holding the
/// previous snapshot can say the charger just moved, which is why that one
/// piece of state lives here rather than in either pure type.
///
/// Shaped after `ClipboardController`: built in
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

    /// The other half of `stop()`, and never called on its own.
    ///
    /// `previous` is what makes the first snapshot a baseline rather than an
    /// event. Left in place across a stop, the first snapshot after the
    /// restart is compared against one from before it, and a charger moved
    /// while the module was switched off fires a peek the instant it comes
    /// back.
    ///
    /// `arming` is re-seeded too, so the module comes back exactly as it
    /// launched. The first snapshot is allowed to warn about a low battery
    /// (see `apply`), so a battery already below a threshold when the
    /// module is re-enabled says so once, as it would on a fresh launch.
    public func reset() {
        previous = nil
        arming = LowBatteryArming()
    }

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

        // Peeks only. Everything above this line still runs while locked or
        // asleep — the panel keeps current truth, and the arming stays
        // honest — but nothing is drawn at a screen nobody is looking at.
        guard activity == .active else { return }

        // The first snapshot is a baseline for *transitions*: launching the
        // app on a plugged-in machine is not the charger being plugged in.
        // A low battery is a state, not a transition, so it is the one thing
        // the first snapshot may announce — launching at 8% on battery is
        // the problem `LowBatteryArming` starts armed to mention.
        guard let previous else {
            if let crossed {
                onEvent?(.lowBattery(threshold: crossed, level: snapshot.level))
            }
            return
        }

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
