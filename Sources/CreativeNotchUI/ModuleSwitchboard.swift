import Foundation
import CreativeNotchCore

/// The one place that knows how to start and stop every module.
///
/// `ROADMAP.md` asks for module toggles "next to the `SystemActivity` gate, in
/// the same place that already knows how to start and stop these subsystems".
/// That place was `AppDelegate` — and it was **three straight-line lists that
/// did not agree with each other**: `hud` in the start and stop lists but not
/// the fan-out, `timer` in the fan-out but neither of the others, the shelf and
/// the transport controls in none of the three. A seven-way preference across
/// three disagreeing lists is twenty-one chances to miss one, silently.
///
/// It holds the resolved `Preferences` and the current `SystemActivity` and
/// composes them per module. **Deliberately not one formula.** "Enabled AND
/// activity" is right for the lifecycle verbs and wrong applied uniformly —
/// see `setActivity(_:)` for the two modules where it is wrong and why.
///
/// It starts at `.allEnabled` rather than loading from the store, so
/// constructing a delegate performs no defaults read: `apply()` is the only
/// thing that consults storage, and it runs from `startSubsystems()`. That is
/// also what lets the existing fan-out suites, which never call `apply()`,
/// keep asserting the ungated behaviour unchanged.
///
/// It registers **nothing** — not with `SystemActivityObserver`, not with the
/// `AppState` funnel, not with `UserDefaults`. It is the one-line addition the
/// fan-out comment promised, wearing a name.
@MainActor
final class ModuleSwitchboard {

    private(set) var preferences: Preferences = .allEnabled
    private(set) var activity: SystemActivity = .active

    private unowned let delegate: AppDelegate

    init(delegate: AppDelegate) {
        self.delegate = delegate
    }

    /// Brings every module into line with the stored preferences.
    ///
    /// **The launch path is the first invocation of the same code a live
    /// toggle runs.** If launch kept its own list, "off at launch" and "turned
    /// off at runtime" would drift — and the one that drifts is always the
    /// launch path, because a developer's machine has every module on.
    ///
    /// Never called from `install(metrics:)`. Fourteen suites call `install`
    /// and then inject their fakes; an `apply()` in there would put a real
    /// repeating `Timer`, a real `perl` subprocess and a real `CGEventTap` in
    /// every one of them.
    func apply() {
        preferences = delegate.preferencesStore.load()
        delegate.state.preferences = preferences

        setEnabled(preferences.hud, for: .hud)
        setEnabled(preferences.clipboard, for: .clipboard)
        setEnabled(preferences.mediaMetadata, for: .mediaMetadata)
        setEnabled(preferences.mediaControls, for: .mediaControls)
        setEnabled(preferences.power, for: .power)
        setEnabled(preferences.timer, for: .timer)
        setEnabled(preferences.shelf, for: .shelf)
    }

    /// Stops everything, regardless of preference.
    ///
    /// A module already stopped stops for free, and **a quit path that
    /// consults a preference is a quit path that can be wrong.** The old stop
    /// list had five entries while the switchboard owns seven.
    func stopAll() {
        delegate.hud?.stop()
        delegate.clipboard?.stop()
        delegate.media?.setEnabled(false)
        delegate.media?.stop()
        delegate.power?.stop()
        delegate.timer?.cancel()
    }

    /// Fans the activity gate out per module.
    ///
    /// **Three different shapes, and the differences are the point rather than
    /// oversights.**
    ///
    /// The clipboard poller and the media helper stop outside `.active`: their
    /// output is only worth producing while somebody can see it.
    ///
    /// The timer is never suspended. `setActive` changes only how often it
    /// wakes to *redraw* the ear — `TimerSchedule.nextWake` schedules the
    /// deadline itself when inactive and nothing before it — and never whether
    /// the deadline fires. It is fanned out **even while the timer module is
    /// disabled**, for as long as a countdown is still running, because it is a
    /// scheduling-rate verb rather than a lifecycle one: freezing `isActive` at
    /// `true` on a disabled-but-running countdown would cost a 25-minute timer
    /// on a locked machine roughly 84 wakes where `TimerSchedule` promises one.
    ///
    /// The power module is not suspended either: `PowerController.setActivity`
    /// suppresses peeks and leaves the observer running, because a
    /// notification-driven source costs nothing idle and suspending it would
    /// mean missing the charger moving while the lid is shut.
    ///
    /// **The HUD has no activity axis and must not gain one.** A uniform
    /// formula would newly stop it on every screen lock, tearing down and
    /// recreating a `CGEventTap` per lock/unlock cycle — and
    /// `MediaKeyMonitor.start()` records success as `isRunning = token != nil`
    /// with no retry, so one `CGEventTapCreate` failure in an unlock window
    /// would leave the HUD silently dead for the session. That window does not
    /// exist today. Do not create it.
    func setActivity(_ next: SystemActivity) {
        activity = next
        let now = Date().timeIntervalSince1970

        delegate.clipboard?.setActivity(next, now: now)
        delegate.media?.setActivity(next)
        delegate.timer?.setActive(next == .active)
        delegate.power?.setActivity(next)
    }

    /// Starts or stops one module, and is the only thing that does.
    ///
    /// `apply()` is this called seven times, which is what makes the launch
    /// path and a live toggle the same code.
    func setEnabled(_ enabled: Bool, for module: ModuleID) {
        preferences[module] = enabled
        delegate.state.preferences = preferences

        switch module {
        case .hud:
            enabled ? delegate.hud?.start() : delegate.hud?.stop()
            if !enabled { delegate.arbiter.clearHUD() }

        case .clipboard:
            if enabled {
                delegate.clipboard?.start()
            } else {
                delegate.clipboard?.stop()
            }

        case .mediaMetadata:
            delegate.media?.setEnabled(enabled)
            if enabled {
                delegate.media?.start()
                if activity != .active { delegate.media?.setActivity(activity) }
            } else {
                delegate.media?.stop()
                delegate.media?.reset()
            }

        case .mediaControls:
            // Lazy `&&`, preference first. Reading `MediaRemoteBridge
            // .isAvailable` is what performs the `dlopen`, and there is no
            // `dlclose` — so the operand order is what makes "off" mean "not
            // loaded" rather than "loaded and hidden".
            delegate.state.showsMediaControls = enabled && delegate.mediaRemoteAvailable()

        case .power:
            if enabled {
                delegate.power?.start()
            } else {
                delegate.power?.stop()
                delegate.power?.reset()
                delegate.state.power = nil
                delegate.arbiter.clearPower()
            }

        case .timer:
            // A running countdown is left to finish and chime: it is state the
            // user deliberately created, and the deadline was already exempt
            // from the activity gate by design. What goes immediately is the
            // tab, and the ability to start a new one.
            if !enabled { delegate.arbiter.dismissTimerDone() }

        case .shelf:
            // Nothing to stop — the shelf owns no timer, observer or process.
            // Disabling it hides the tab and refuses drops, which the drop
            // closures read from `state.preferences`.
            break
        }

        delegate.modulesDidChange()
    }
}
