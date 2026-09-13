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
        setEnabled(preferences.hotkey, for: .hotkey)
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
        // The hotkey is deliberately absent. `stopAll()` runs only from
        // `applicationWillTerminate`, and Apple's header is explicit that the
        // system reclaims hotkey registrations when the process exits -- so a
        // stop here would be teardown for something that cannot happen, and no
        // test could distinguish it from the system doing its job.
        //
        // The registration IS dropped when the module is switched off, which
        // is the case that can actually go wrong: see the `.hotkey` leg.
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
    ///
    /// **Three asymmetries below are deliberate, not oversights.** A running
    /// countdown is not cancelled; `hasBattery` is never cleared, because
    /// capability and preference are two different questions; and the shelf
    /// and transport legs stop nothing, because they own nothing to stop.
    func setEnabled(_ enabled: Bool, for module: ModuleID, persist: Bool = false) {
        preferences[module] = enabled
        if persist { delegate.preferencesStore.setEnabled(enabled, for: module) }
        delegate.state.preferences = preferences

        switch module {
        case .hud:
            if enabled {
                delegate.hud?.start()
            } else {
                delegate.hud?.stop()
                delegate.arbiter.clearHUD()
            }

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
                // Re-apply the gate: enabling while the screen is locked must
                // not leave a helper running that the gate would have stopped.
                if activity != .active { delegate.media?.setActivity(activity) }
            } else {
                delegate.media?.stop()
                // `reset()` publishes the absence rather than merely stopping
                // the production of presence -- it calls `onChange(nil)`,
                // which is wired to `nowPlayingDidChange`. That matters: a
                // stale badge widens the closed notch's hit-test region for
                // the rest of the session.
                //
                // An explicit `nowPlayingDidChange(nil)` here was tried and
                // removed: mutation showed it unobservable, because `reset()`
                // has already done it by the time it would run.
                delegate.media?.reset()
            }

        case .mediaControls:
            // Lazy `&&`, **preference first, and the order is load-bearing**.
            // Reading `MediaRemoteBridge.isAvailable` is what performs the
            // `dlopen`, and there is no `dlclose` — so the reverse spelling
            // compiles, looks identical on screen, and loads a private
            // framework the user just declined.
            delegate.state.showsMediaControls = enabled && delegate.mediaRemoteAvailable()
            delegate.state.onMediaCommand = enabled
                ? { command in MediaRemoteBridge.send(command) }
                : nil

        case .power:
            if enabled {
                delegate.power?.start()
            } else {
                delegate.power?.stop()
                delegate.power?.reset()
                delegate.state.power = nil
                delegate.arbiter.clearPower()
                // `hasBattery` is NOT cleared. It answers "can this machine do
                // it", which is not "does the user want it", and it is
                // rewritten on every power notification — so a conflated field
                // would be clobbered by the hardware and the preference would
                // silently revert.
            }

        case .timer:
            if enabled {
                delegate.wireTimerActions()
            } else {
                // The tab goes now and no new countdown can start, but a
                // running one finishes and chimes: it is state the user
                // deliberately created, and the deadline was already exempt
                // from the activity gate by design.
                //
                // `onChange` and `onFinished` are deliberately NOT nilled.
                // They are the publish and finish paths; nilling them for
                // symmetry is what would silently break the surviving
                // countdown.
                delegate.state.onStartTimer = nil
                delegate.state.onPauseTimer = nil
                delegate.state.onResumeTimer = nil
                delegate.state.onCancelTimer = nil
                delegate.arbiter.dismissTimerDone()
            }

        case .hotkey:
            // Stopping means UNREGISTERING, not ignoring the callback. A
            // registration alive while the switch reads off is exactly the
            // failure this module exists to prevent -- and dropping the last
            // one takes the process-wide Carbon handler with it.
            //
            // No activity axis, like the HUD: a hotkey whose purpose is to
            // open the panel from anywhere must keep working while the panel
            // is closed, and there is nothing running between presses to
            // suspend.
            delegate.hotkey?.setEnabled(enabled)

        case .shelf:
            // Nothing to stop: the shelf owns no timer, observer or process,
            // and its idle cost is genuinely zero. Disabling hides the tab and
            // refuses drops — the drop closures read `state.preferences`.
            delegate.state.shelf = enabled ? delegate.shelf : nil
        }

        retargetTabsIfNeeded()
        delegate.modulesDidChange()
    }

    /// Moves the selection off a tab that has just disappeared.
    ///
    /// **Both the live state and `lastOpenTab`.** Correcting only the live one
    /// leaves the notch-tap reopen to fire later from `.open(lastOpenTab)`,
    /// long after the toggle — the hardest version of this bug to reproduce
    /// and the easiest to dismiss as a glitch.
    ///
    /// This is the first thing in the app's history that turns a tab off while
    /// the panel is open; `hasBattery` only ever turned one on.
    private func retargetTabsIfNeeded() {
        let visible = TabVisibility.visible(
            enabled: preferences,
            hasBattery: delegate.state.hasBattery
        )

        if case .open(let tab) = delegate.state.state, !visible.contains(tab) {
            delegate.state.transition(to: visible.first.map { .open($0) } ?? .closed)
        }
        if !visible.contains(delegate.state.lastOpenTab), let first = visible.first {
            delegate.state.retarget(lastOpenTab: first)
        }
    }
}
