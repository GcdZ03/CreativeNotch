import AppKit
import Observation
import CreativeNotchCore

/// Owns the one hotkey: what it is, whether it is registered, and whether the
/// user has proved it works.
///
/// The lifecycle shape is `ClipboardController`'s: `start()` and `stop()` are
/// idempotent, and `stop()` genuinely drops the registration rather than
/// ignoring the callback -- which is what lets the Preferences leg mean what
/// it says.
///
/// It has **no activity axis**. A hotkey whose whole purpose is to open the
/// panel from anywhere must keep working while the panel is closed, and there
/// is nothing running between presses to suspend. It joins the
/// switchboard on the preference alone.
///
/// **`@Observable`, because the settings row holds it as a plain `let`.** The
/// window above the row observes only `AppState`, which none of these verbs
/// touch, so without this a recorded combination or a Clear left the row
/// showing the old label and the old "Press it now to confirm" until something
/// unrelated happened to redraw it. Confirmation is the sharpest case: it
/// arrives from a keypress anywhere, with the window untouched.
@MainActor
@Observable
final class HotKeyController {

    /// What the settings row shows, and the only state it needs.
    enum Status: Equatable, Sendable {
        /// No combination chosen. The shipped state.
        case unset
        /// Registered, but the user has not pressed it yet. Registration
        /// success says nothing about delivery.
        case awaitingConfirmation
        /// Registered, and observed to fire.
        case confirmed
        /// The system refused the registration, with copy that differs by
        /// reason -- a modifier-policy rejection is not the same news as a
        /// combination another app holds exclusively.
        case failed(String)
    }

    @ObservationIgnored private let store: HotKeyStore
    @ObservationIgnored private let center: HotKeyCenter
    @ObservationIgnored private var registrationID: UInt32?
    @ObservationIgnored private var isEnabled = true

    /// Called when the hotkey fires. Set by `AppDelegate`.
    @ObservationIgnored var onTrigger: (() -> Void)?

    /// Whether macOS lists a combination as an enabled symbolic hotkey. A
    /// seam, so tests do not depend on this machine's System Settings, and a
    /// closure rather than a value so `CopySymbolicHotKeys` -- which Apple
    /// says not to call unnecessarily -- runs only for a combination that has
    /// passed every cheaper check.
    @ObservationIgnored var isSystemReserved: (HotKeyCombo) -> Bool = { SymbolicHotKeys.isReserved($0) }

    /// Why the last recorded combination was refused, or `nil`. Separate from
    /// `status` because a refusal leaves the existing shortcut in place: the
    /// row says both what it still is and why the new one was not taken.
    private(set) var rejection: HotKeyValidation.Rejection?

    /// Published so the settings row can redraw. `private(set)` because the
    /// only writers are this type's own verbs.
    private(set) var status: Status = .unset

    init(store: HotKeyStore, center: HotKeyCenter = .shared) {
        self.store = store
        self.center = center
        let saved = store.load()
        self.combo = saved
        self.status = Self.status(for: saved, confirmed: store.isConfirmed)
    }

    /// A stored copy of what the store holds, not a read through to it:
    /// `UserDefaults` is invisible to observation, so a computed read would
    /// leave the row's label stale. Only `setCombo` writes either.
    private(set) var combo: HotKeyCombo?

    /// Whether a registration is live. Exposed for the same reason
    /// `PowerObserver.registrationCount` is: a stop that is asserted rather
    /// than observed is not a stop.
    var isRegistered: Bool { registrationID != nil }

    // MARK: - Lifecycle

    func start() {
        guard isEnabled, registrationID == nil, let combo = store.load() else { return }
        registerCurrent(combo)
    }

    func stop() {
        guard let id = registrationID else { return }
        center.unregister(id)
        registrationID = nil
    }

    /// Only ever called by `ModuleSwitchboard`. The latch exists as well as
    /// the switchboard for the reason `MediaController`'s does: it makes the
    /// controller safe to call by somebody who has not read the switchboard.
    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if enabled { start() } else { stop() }
    }

    // MARK: - Choosing a combination

    /// What the recorder calls: validate, then either refuse with a reason or
    /// take the combination.
    ///
    /// **A refusal changes nothing else.** The shortcut already set stays set
    /// and registered; the row shows why the new one was not taken. Without
    /// this gate a bare Space, a bare letter or ⌘C became an exclusive
    /// system-wide hotkey -- each registers cleanly, and the API says nothing.
    ///
    /// `taken` is empty because this app has one hotkey: re-recording the
    /// current combination is a no-op, not a conflict.
    func record(_ candidate: HotKeyCombo) {
        // The cheap checks first, so the symbolic-hotkey read is made only
        // for a combination that would otherwise be accepted.
        let reason = HotKeyValidation.rejection(for: candidate)
            ?? HotKeyValidation.rejection(for: candidate, systemReserved: isSystemReserved(candidate))
        if let reason {
            rejection = reason
            return
        }
        setCombo(candidate)
    }

    /// Records a new combination, replacing whatever was there.
    ///
    /// **The old registration is dropped first.** Registering the new one
    /// without unregistering the old leaves both live, and the old one keeps
    /// opening the panel -- a bug nobody would think to look for.
    @discardableResult
    func setCombo(_ combo: HotKeyCombo?) -> Status {
        stop()
        rejection = nil
        // Always clears the confirmation: the proof was about the old
        // combination.
        store.save(combo)
        self.combo = combo

        guard let combo else {
            status = .unset
            return status
        }
        if isEnabled { registerCurrent(combo) } else { status = .awaitingConfirmation }
        return status
    }

    private func registerCurrent(_ combo: HotKeyCombo) {
        do {
            registrationID = try center.register(combo) { [weak self] in
                self?.didFire()
            }
            status = store.isConfirmed ? .confirmed : .awaitingConfirmation
        } catch let error as HotKeyError {
            registrationID = nil
            status = .failed(Self.message(for: error))
        } catch {
            registrationID = nil
            status = .failed(String(localized: "The system refused this combination.", bundle: .creativeNotch))
        }
    }

    /// The hotkey fired. **This is the only thing that can confirm it** --
    /// neither `OSStatus` nor `CopySymbolicHotKeys` proves delivery.
    func didFire() {
        if status == .awaitingConfirmation {
            store.markConfirmed()
            status = .confirmed
        }
        onTrigger?()
    }

    // MARK: - Copy

    private static func status(for combo: HotKeyCombo?, confirmed: Bool) -> Status {
        guard combo != nil else { return .unset }
        return confirmed ? .confirmed : .awaitingConfirmation
    }

    /// The row's copy for a refusal. **None claims another app holds the
    /// combination** -- that conflict is undetectable, so the pane must never
    /// say it.
    static func message(for rejection: HotKeyValidation.Rejection) -> String {
        switch rejection {
        case .noModifiers:
            return String(localized: "Add a modifier such as \u{2318} or \u{2325}. On its own, that key would be taken away from every app.", bundle: .creativeNotch)
        case .shiftOnly:
            return String(localized: "Add \u{2318}, \u{2325} or \u{2303}. Shift alone is too close to ordinary typing.", bundle: .creativeNotch)
        case .standardShortcut:
            return String(localized: "Every app uses this shortcut. Choose a different one.", bundle: .creativeNotch)
        case .alreadyUsedInThisApp:
            return String(localized: "CreativeNotch already uses this shortcut.", bundle: .creativeNotch)
        case .usedByMacOS:
            return String(localized: "macOS already uses this shortcut, so it would never reach CreativeNotch.", bundle: .creativeNotch)
        }
    }

    /// Three refusals needing three different things said. Treating them all
    /// as a generic failure is the trap: a modifier-policy rejection is the
    /// user's combination being disallowed, which they can fix by choosing
    /// another, and it is not the same news as anything else.
    static func message(for error: HotKeyError) -> String {
        switch error {
        case .exclusiveConflict:
            return String(localized: "Another app has claimed this combination exclusively. Choose a different one.", bundle: .creativeNotch)
        case .rejectedBySystem:
            return String(localized: "macOS refused this combination. Try adding another modifier.", bundle: .creativeNotch)
        case .handlerInstallFailed:
            return String(localized: "CreativeNotch could not listen for shortcuts. Restarting the app usually fixes this.", bundle: .creativeNotch)
        case .other:
            return String(localized: "The system refused this combination.", bundle: .creativeNotch)
        }
    }
}
