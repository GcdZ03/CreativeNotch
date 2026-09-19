import Foundation

/// Whether this copy of the app may touch the login-item service at all.
///
/// **A status read is a write.** One record exists per bundle identifier,
/// and its URL follows whichever copy last read `.status` — no registration
/// call needed (`docs/research/2026-09-19-launch-at-login-probe.md`, Q3).
/// So a dev build in `dist/` that merely drew the Settings row would
/// repoint the user's login item at a bundle `dev.sh` deletes on its next
/// run, and the symptom — "it stopped launching at login" — would appear
/// days later with nothing logged.
///
/// This decides from the path, before the read.
public enum LaunchAtLoginEligibility: Equatable, Sendable {
    case eligible
    case notInstalled

    /// `/Applications` and the user's own `~/Applications`.
    public static var defaultInstallDirectories: [String] {
        ["/Applications", NSHomeDirectory() + "/Applications"]
    }

    /// Eligible when the bundle sits **directly inside** an install
    /// directory.
    ///
    /// A whitelist rather than a blacklist of throwaway locations, because
    /// the blacklist cannot be enumerated — `dist/`, DerivedData, a temp
    /// directory, a mounted image, Downloads — and guessing wrong fails
    /// silently. The cost is refusing a copy deliberately kept elsewhere,
    /// and the row names the path so that refusal can be read.
    public static func resolve(
        bundlePath: String,
        installDirectories: [String] = defaultInstallDirectories
    ) -> LaunchAtLoginEligibility {
        // Compared as whole paths after standardizing, never as a string
        // prefix: a prefix match accepts `/Applications.old/CreativeNotch.app`,
        // and a bare `contains` accepts `/Applications/Utilities/CreativeNotch.app`.
        // `standardizingPath` returns a `String`, hence the second cast.
        let standardized = (bundlePath as NSString).standardizingPath
        let parent = (standardized as NSString).deletingLastPathComponent
        for directory in installDirectories
        where (directory as NSString).standardizingPath == parent {
            return .eligible
        }
        return .notInstalled
    }
}

/// What the Settings row shows.
///
/// Derived from the system on every read, never from a stored `Bool`: the
/// user can turn the login item off in System Settings and macOS does not
/// tell us (spec §2).
public enum LaunchAtLoginState: Equatable, Sendable {
    case on
    case off
    /// macOS is holding the registration until the user allows it.
    case needsApproval
    /// This copy is not installed, so it never asked. Carries the path, so
    /// the row can say which copy is running rather than only that
    /// something is wrong.
    case unavailable(bundlePath: String)

    /// From `SMAppService.Status.rawValue`, which Core does not import.
    ///
    /// `0` (notRegistered) and `3` (notFound) both read as off. They differ
    /// in the record — a disabled tombstone versus no record at all — and
    /// nothing in the UI acts on that difference, so nothing here pretends
    /// to.
    ///
    /// Anything unrecognised is off. A future value read as `on` would be a
    /// switch claiming a registration nobody made, which is the one
    /// direction this module must never fail in.
    public static func from(rawStatus: Int) -> LaunchAtLoginState {
        switch rawStatus {
        case 1:  return .on
        case 2:  return .needsApproval
        default: return .off
        }
    }
}
