import AppKit
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
@MainActor
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

    private let store: HotKeyStore
    private let center: HotKeyCenter
    private var registrationID: UInt32?
    private var isEnabled = true

    /// Called when the hotkey fires. Set by `AppDelegate`.
    var onTrigger: (() -> Void)?

    /// Published so the settings row can redraw. `private(set)` because the
    /// only writers are this type's own verbs.
    private(set) var status: Status = .unset

    init(store: HotKeyStore, center: HotKeyCenter = .shared) {
        self.store = store
        self.center = center
        self.status = Self.status(for: store.load(), confirmed: store.isConfirmed)
    }

    var combo: HotKeyCombo? { store.load() }

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

    /// Records a new combination, replacing whatever was there.
    ///
    /// **The old registration is dropped first.** Registering the new one
    /// without unregistering the old leaves both live, and the old one keeps
    /// opening the panel -- a bug nobody would think to look for.
    @discardableResult
    func setCombo(_ combo: HotKeyCombo?) -> Status {
        stop()
        // Always clears the confirmation: the proof was about the old
        // combination.
        store.save(combo)

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
            status = .failed("The system refused this combination.")
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

    /// Three refusals needing three different things said. Treating them all
    /// as a generic failure is the trap: a modifier-policy rejection is the
    /// user's combination being disallowed, which they can fix by choosing
    /// another, and it is not the same news as anything else.
    static func message(for error: HotKeyError) -> String {
        switch error {
        case .exclusiveConflict:
            return "Another app has claimed this combination exclusively. Choose a different one."
        case .rejectedBySystem:
            return "macOS refused this combination. Try adding another modifier."
        case .handlerInstallFailed:
            return "CreativeNotch could not listen for shortcuts. Restarting the app usually fixes this."
        case .other:
            return "The system refused this combination."
        }
    }
}
