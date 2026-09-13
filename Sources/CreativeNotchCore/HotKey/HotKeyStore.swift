import Foundation

/// Persists the chosen combination, and whether the user has proved it works.
///
/// **Absent means genuinely absent.** Unlike the module toggles, whose absent
/// key resolves to the shipped default of ON, there is no default hotkey --
/// any default risks colliding with whatever launcher the user already runs,
/// and a colliding hotkey either double-fires or is silently eaten. So this
/// resolves to `nil`, and `nil` is a legal, expected, shipped state.
///
/// The confirmation is stored beside the combination rather than derived,
/// because it is evidence: the user pressed the key and the handler fired.
/// Nothing else can establish that.
public final class HotKeyStore {

    public enum Keys {
        public static let combo = "hotkey.openPanel.combo"
        public static let confirmed = "hotkey.openPanel.confirmed"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> HotKeyCombo? {
        guard let data = defaults.data(forKey: Keys.combo) else { return nil }
        // A value of the wrong shape reads as absent and is NOT rewritten --
        // the same policy the module toggles use. The user keeps the evidence
        // of whatever they wrote, and the app behaves as though unset.
        return try? JSONDecoder().decode(HotKeyCombo.self, from: data)
    }

    /// Writing a combination **clears the confirmation**, always.
    ///
    /// The proof was about the old combination. Carrying it over to a new one
    /// would show a tick beside a key nobody has ever pressed, which is worse
    /// than showing no tick at all.
    public func save(_ combo: HotKeyCombo?) {
        defaults.set(false, forKey: Keys.confirmed)
        guard let combo, let data = try? JSONEncoder().encode(combo) else {
            defaults.removeObject(forKey: Keys.combo)
            return
        }
        defaults.set(data, forKey: Keys.combo)
    }

    public var isConfirmed: Bool {
        defaults.bool(forKey: Keys.confirmed)
    }

    /// Recorded only when the handler actually fired for this combination.
    public func markConfirmed() {
        defaults.set(true, forKey: Keys.confirmed)
    }
}
