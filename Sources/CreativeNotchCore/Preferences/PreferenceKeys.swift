import Foundation

/// The defaults keys, and the one function that decides what a stored value
/// means.
///
/// **Deliberately not private.** A `private static let` for each key would
/// force the tests to re-spell every literal; with one key that is tolerable,
/// with seven a typo in the *source* makes the test pass against a key nobody
/// writes — a test asserting a literal against itself.
public enum PreferenceKeys {
    /// `module.<id>.enabled`, e.g. `module.media-metadata.enabled`.
    ///
    /// Dotted, lowercase, module-first: it sorts by module under `defaults
    /// read`, it greps, and it namespaces away from the two legacy keys
    /// (`hasCompletedOnboarding`, `HUDDiagnostics`) left behind by the
    /// onboarding window and the system HUD, both since removed.
    public static func enabled(_ module: ModuleID) -> String {
        "module.\(module.rawValue).enabled"
    }

    /// Whether the first-run welcome card has been dismissed (2026-10-24).
    ///
    /// A new key rather than the legacy `hasCompletedOnboarding`: someone who
    /// finished that window long ago has never seen this card, and reusing
    /// the key would hide it from exactly the people most likely to have
    /// forgotten what the notch does. Absent means not yet seen.
    public static let welcomeSeen = "welcome.seen"

    /// Which display the notch lives on (2026-10-24), as a `DisplayChoice`
    /// raw value. Absent means following the focused window, the behaviour
    /// from before the setting existed.
    public static let showOn = "display.showOn"

    /// What a raw "Show on" value means. A string naming no choice, or a
    /// value of another type, reads as the default and is not rewritten --
    /// the policy `resolveEnabled` sets out below.
    public static func resolveDisplayChoice(_ raw: Any?) -> DisplayChoice {
        guard let string = raw as? String, let choice = DisplayChoice(rawValue: string) else {
            return .default
        }
        return choice
    }

    /// How large the open panel's text is (2026-10-24), as a `TextSize` raw
    /// value. Absent means the default, the look from before the setting.
    public static let textSize = "display.textSize"

    /// What a raw "Text size" value means, by the policy `resolveDisplayChoice`
    /// follows: anything that names no size reads as the default and is left
    /// in place.
    public static func resolveTextSize(_ raw: Any?) -> TextSize {
        guard let string = raw as? String, let size = TextSize(rawValue: string) else {
            return .default
        }
        return size
    }

    // The layout options (2026-10-24), read by `PreferencesStore.loadLayout`.
    // Absent means the default, the look from before the setting.

    /// A `PanelWidth` raw value.
    public static let layoutWidth = "layout.width"
    /// A `PanelCorners` raw value.
    public static let layoutCorners = "layout.corners"
    /// An `EarSide` raw value: which ear holds the tabs.
    public static let layoutTabsSide = "layout.tabsSide"
    /// A boolean: the battery cell in the header.
    public static let layoutShowsBattery = "layout.showsBattery"
    /// A boolean: the now-playing badge beside the closed notch.
    public static let layoutShowsNowPlayingBadge = "layout.badge.nowPlaying"
    /// A boolean: the countdown badge beside the closed notch.
    public static let layoutShowsTimerBadge = "layout.badge.timer"

    /// What a raw value for one of the layout menus means, by the policy
    /// `resolveTextSize` follows: anything that names no choice reads as
    /// `fallback` and is left in place.
    public static func resolveChoice<Choice: RawRepresentable>(
        _ raw: Any?, default fallback: Choice
    ) -> Choice where Choice.RawValue == String {
        guard let string = raw as? String, let choice = Choice(rawValue: string) else {
            return fallback
        }
        return choice
    }

    // The adjustable limits (2026-10-24), read by `PreferencesStore.loadLimits`
    // through the resolvers on `Limits`. Subsystem-first, like the module
    // toggles, so `defaults read` groups each with its module.

    /// How a picked colour is copied (2026-10-24), as a `ColorFormat` raw
    /// value. Absent means hex. Module-first, like the limits.
    public static let colorFormat = "color-picker.format"

    /// What a raw "Copy as" value means, by the policy `resolveDisplayChoice`
    /// follows: anything that names no format reads as hex and is left in
    /// place.
    public static func resolveColorFormat(_ raw: Any?) -> ColorFormat {
        guard let string = raw as? String, let format = ColorFormat(rawValue: string) else {
            return .default
        }
        return format
    }

    /// One of `Limits.shelfCapacityChoices`, as an integer.
    public static let shelfCapacity = "shelf.capacity"
    /// Days as an integer, `0` for never: `ShelfExpiry`'s raw value.
    public static let shelfExpiryDays = "shelf.expiryDays"
    /// One of `Limits.clipboardCapacityChoices`, as an integer.
    public static let clipboardCapacity = "clipboard.capacity"
    /// An array of three integers, in minutes.
    public static let timerPresets = "timer.presets"
    /// An `NSSound` name, or "None": `ChimeSound`'s raw value.
    public static let timerChime = "timer.chime"

    /// Whether a timer that finishes while the notch is hidden for a
    /// full-screen app also posts a notification (2026-10-24). A boolean
    /// read through `resolveEnabled`, so absent means on.
    public static let timerNotifyWhenHidden = "timer.notifyWhenHidden"

    /// Bundle identifiers whose copies clipboard history ignores
    /// (2026-10-24), as an array of strings read through
    /// `ClipboardExclusions.resolve`. Absent means none.
    public static let clipboardExcludedApps = "clipboard.excludedApps"

    /// What a raw defaults value means.
    ///
    /// This is the whole compatibility surface, which is why it is a pure
    /// function of `Any?` rather than a method on the store: it is pinned with
    /// `#expect` and tested with no `UserDefaults` instance in sight.
    ///
    /// **Absent means the shipped default, and for a module toggle that is
    /// on.** `UserDefaults.bool(forKey:)` returns `false` for an absent key,
    /// which is the wrong polarity for a set of enable-flags: the failure mode
    /// is the entire app going dark on a fresh install, with the preferences
    /// window truthfully reporting that the user turned everything off. The
    /// domain is emptied routinely — `Scripts/dev.sh --fresh` deletes all of
    /// it, and the README tells users to delete it on uninstall — so "every
    /// key absent" is a normal state rather than a first-launch edge case.
    ///
    /// **A value of the wrong type is treated as absent, and is not
    /// rewritten.** Someone who ran `defaults write … -string yes` gets
    /// working software *and* keeps the evidence of what they typed; silently
    /// correcting the key would make the next `defaults read` lie to them.
    public static func resolveEnabled(_ raw: Any?, shippedDefault: Bool = true) -> Bool {
        guard let raw else { return shippedDefault }
        // `object(forKey:)` hands back `NSNumber` for a boolean written
        // through either `set(_:forKey:)` or `defaults write -bool`, so the
        // bridge to `Bool` is the honest check. A `String` — what `defaults
        // write` produces without `-bool` — deliberately falls through to the
        // shipped default rather than being parsed, because "yes" parsing to
        // true and "yep" parsing to false is a worse surprise than neither.
        guard let number = raw as? NSNumber else { return shippedDefault }
        return number.boolValue
    }
}
