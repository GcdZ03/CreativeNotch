import Foundation

/// Reads and writes the module toggles, and the adjustable limits.
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
                defaults.object(forKey: PreferenceKeys.enabled(module)),
                shippedDefault: module.shippedDefault
            )
        }
        return preferences
    }

    public func setEnabled(_ enabled: Bool, for module: ModuleID) {
        defaults.set(enabled, forKey: PreferenceKeys.enabled(module))
    }

    /// Whether the welcome card has been dismissed. Read through
    /// `resolveEnabled` like every other flag, so a hand-typed string reads as
    /// not seen and is left in place.
    public var hasSeenWelcome: Bool {
        PreferenceKeys.resolveEnabled(
            defaults.object(forKey: PreferenceKeys.welcomeSeen), shippedDefault: false
        )
    }

    /// Which display the notch lives on. Read on every call, never cached.
    public var displayChoice: DisplayChoice {
        PreferenceKeys.resolveDisplayChoice(defaults.object(forKey: PreferenceKeys.showOn))
    }

    public func setDisplayChoice(_ choice: DisplayChoice) {
        defaults.set(choice.rawValue, forKey: PreferenceKeys.showOn)
    }

    /// How large the open panel's text is. Read on every call, never cached.
    public var textSize: TextSize {
        PreferenceKeys.resolveTextSize(defaults.object(forKey: PreferenceKeys.textSize))
    }

    public func setTextSize(_ size: TextSize) {
        defaults.set(size.rawValue, forKey: PreferenceKeys.textSize)
    }

    /// `false` removes the key rather than writing `false`, so "Show Welcome
    /// Again" leaves the domain reading exactly like a fresh install's.
    public func setHasSeenWelcome(_ seen: Bool) {
        if seen {
            defaults.set(true, forKey: PreferenceKeys.welcomeSeen)
        } else {
            defaults.removeObject(forKey: PreferenceKeys.welcomeSeen)
        }
    }

    /// The adjustable limits (2026-10-24). Every key read through the
    /// resolvers on `Limits`, so a missing or hand-mangled value reads as the
    /// old hard-coded number and is left in place for `defaults read`.
    public func loadLimits() -> Limits {
        Limits(
            shelfCapacity: Limits.resolveChoice(
                defaults.object(forKey: PreferenceKeys.shelfCapacity),
                among: Limits.shelfCapacityChoices, default: Limits.defaultShelfCapacity
            ),
            shelfExpiry: Limits.resolveExpiry(defaults.object(forKey: PreferenceKeys.shelfExpiryDays)),
            clipboardCapacity: Limits.resolveChoice(
                defaults.object(forKey: PreferenceKeys.clipboardCapacity),
                among: Limits.clipboardCapacityChoices, default: Limits.defaultClipboardCapacity
            ),
            timerPresets: Limits.resolvePresets(defaults.object(forKey: PreferenceKeys.timerPresets)),
            chime: Limits.resolveChime(defaults.object(forKey: PreferenceKeys.timerChime))
        )
    }

    /// Writes every limit, not only the one that changed: they arrive as one
    /// value, and a partial write is a second way for the domain and the app
    /// to disagree.
    public func saveLimits(_ limits: Limits) {
        defaults.set(limits.shelfCapacity, forKey: PreferenceKeys.shelfCapacity)
        defaults.set(limits.shelfExpiry.rawValue, forKey: PreferenceKeys.shelfExpiryDays)
        defaults.set(limits.clipboardCapacity, forKey: PreferenceKeys.clipboardCapacity)
        defaults.set(limits.timerPresets, forKey: PreferenceKeys.timerPresets)
        defaults.set(limits.chime.rawValue, forKey: PreferenceKeys.timerChime)
    }
}
