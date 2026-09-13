import Foundation

/// The defaults keys, and the one function that decides what a stored value
/// means.
///
/// **Deliberately not private.** `OnboardingController`'s `private static let
/// seenKey` forced its tests to re-spell the literal four times; with one key
/// that is tolerable, with seven a typo in the *source* makes the test pass
/// against a key nobody writes — a test asserting a literal against itself.
public enum PreferenceKeys {
    /// `module.<id>.enabled`, e.g. `module.media-metadata.enabled`.
    ///
    /// Dotted, lowercase, module-first: it sorts by module under `defaults
    /// read`, it greps, and it namespaces away from the two legacy keys
    /// (`hasCompletedOnboarding`, `HUDDiagnostics`), which are grandfathered
    /// exactly as they are.
    public static func enabled(_ module: ModuleID) -> String {
        "module.\(module.rawValue).enabled"
    }

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
