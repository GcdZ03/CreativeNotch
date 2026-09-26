import Foundation

/// Reads and writes the module toggles.
///
/// Takes an injectable suite, so tests run against an isolated store rather
/// than the developer's real `com.gcdz.creativenotch` domain.
///
/// **It caches nothing.** A cached `Preferences` is a second source of truth
/// that has to be invalidated, and the pattern it would copy — a `let` that
/// reads the defaults domain once at construction — is precisely the one this
/// module must not repeat: a preference read once at construction is a
/// preference that appears to work in the window and changes nothing until
/// relaunch.
public final class PreferencesStore {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> Preferences {
        var preferences = Preferences()
        for module in ModuleID.allCases {
            preferences[module] = PreferenceKeys.resolveEnabled(
                defaults.object(forKey: PreferenceKeys.enabled(module))
            )
        }
        return preferences
    }

    public func setEnabled(_ enabled: Bool, for module: ModuleID) {
        defaults.set(enabled, forKey: PreferenceKeys.enabled(module))
    }
}
