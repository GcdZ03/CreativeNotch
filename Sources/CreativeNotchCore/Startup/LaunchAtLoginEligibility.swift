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
    ///
    /// `Scripts/install.sh` installs to the first of these. Its `INSTALL_DIR`
    /// override puts the app somewhere this list does not know, which leaves
    /// the toggle permanently unavailable — said out loud in that script
    /// rather than left for someone to discover.
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
    ///
    /// Comparison is by whole standardized path, never a prefix: a prefix
    /// match accepts `/Applications.old/CreativeNotch.app`, and a bare
    /// `contains` accepts `/Applications/Utilities/CreativeNotch.app`.
    ///
    /// Two spellings of the same directory are the same directory, so when
    /// the strings disagree the **identity** of the two directories decides.
    /// That settles three things at once and in the only safe direction:
    /// a case-only difference on a case-insensitive volume
    /// (`/applications` versus `/Applications`), a firmlink
    /// (`/System/Volumes/Data/Applications`), and a symlinked install
    /// directory. Comparing case-*insensitively* instead would be a real
    /// hole — on a case-sensitive volume those are genuinely different
    /// directories — whereas identity is the question actually being asked.
    ///
    /// The fallback only ever turns a wrong refusal into a correct accept:
    /// it runs when the strings already disagreed, and answers only when the
    /// filesystem says both paths are one directory. Anything it cannot
    /// resolve — either path missing, no identifier available — stays
    /// refused.
    public static func resolve(
        bundlePath: String,
        installDirectories: [String] = defaultInstallDirectories
    ) -> LaunchAtLoginEligibility {
        // `standardizingPath` removes `..` **lexically**, which can cross a
        // symlink and land somewhere the real path never goes:
        // `/tmp/../Applications/X.app` becomes `/Applications/X.app`, while
        // `/tmp` is a symlink to `/private/tmp` and the true parent is
        // `/private/Applications`. Resolving it properly would mean touching
        // the filesystem, which this function must not do; refusing it costs
        // nothing, because no bundle path macOS hands an app contains `..`.
        guard !(bundlePath as NSString).pathComponents.contains("..") else {
            return .notInstalled
        }

        // `standardizingPath` returns a `String`, hence the second cast.
        let standardized = (bundlePath as NSString).standardizingPath
        let parent = (standardized as NSString).deletingLastPathComponent

        let directories = installDirectories.map { ($0 as NSString).standardizingPath }

        // Strings first: pure, allocation-cheap, and the answer for every
        // path macOS actually hands a running app.
        if directories.contains(parent) { return .eligible }

        // Only then the filesystem, and only for the ones that disagreed.
        for directory in directories where isSameDirectory(parent, directory) {
            return .eligible
        }
        return .notInstalled
    }

    /// Whether two paths name one directory on disk.
    ///
    /// Compared by file resource identifier rather than by string, which is
    /// what makes case, firmlinks and symlinks all moot in a single step.
    /// Everything about it fails closed: a path that does not exist, a
    /// volume that supplies no identifier, or any thrown error answers
    /// `false`, leaving the caller's refusal standing.
    private static func isSameDirectory(_ lhs: String, _ rhs: String) -> Bool {
        guard lhs != rhs else { return true }
        let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey, .isDirectoryKey]
        // `resourceValues` does NOT follow a symlink: asked about a link to a
        // directory it answers `isDirectory == false` and hands back the
        // link's own identifier, so the comparison would fail for exactly the
        // case this fallback exists to catch. Measured, not assumed.
        guard
            let left = try? URL(fileURLWithPath: lhs).resolvingSymlinksInPath()
                .resourceValues(forKeys: keys),
            let right = try? URL(fileURLWithPath: rhs).resolvingSymlinksInPath()
                .resourceValues(forKeys: keys),
            left.isDirectory == true, right.isDirectory == true,
            let leftID = left.fileResourceIdentifier,
            let rightID = right.fileResourceIdentifier
        else { return false }
        return leftID.isEqual(rightID)
    }
}

/// What the Settings row shows.
///
/// Derived from the system on every read, never from a stored `Bool`: the
/// user can turn the login item off in System Settings and macOS does not
/// tell us (spec §2).
public enum LaunchAtLoginState: Equatable, Sendable {
    /// Eligible, but nothing has been read yet.
    ///
    /// **Distinct from `.off` on purpose.** A guess that renders as a
    /// measurement is the failure this module exists to prevent, and
    /// collapsing the two also costs a test: a controller whose initialiser
    /// *does* read the system returns `.off` for an unregistered app, so
    /// with one value for both, "the initialiser read nothing" could not be
    /// asserted behaviourally at all.
    case unread
    case on
    case off
    /// macOS is holding the registration until the user allows it.
    ///
    /// The switch reads **off** here, so the only gesture the row offers is
    /// "turn on", which registers again. There is deliberately no way to
    /// withdraw a pending registration from this app: reading it as on would
    /// claim a login item that does not yet work, and that is the one
    /// direction this module must never fail in. The manual route is the
    /// button beside the switch. Unmeasured — the probe could not produce
    /// this state, because it needs a person to deny the item in System
    /// Settings.
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
    /// direction this module must never fail in. Never `.unread`: that means
    /// "not asked", and this function is only ever called with an answer.
    public static func from(rawStatus: Int) -> LaunchAtLoginState {
        switch rawStatus {
        case 1:  return .on
        case 2:  return .needsApproval
        default: return .off
        }
    }

    /// Whether the switch reads as on. Only a registration the system
    /// confirmed counts.
    public var isOn: Bool { self == .on }

    /// Whether the row can be operated at all.
    ///
    /// The second barrier in front of the rule in `LaunchAtLoginEligibility`:
    /// the controller refuses the call, and the row refuses the gesture.
    public var isOperable: Bool {
        switch self {
        case .unavailable: return false
        case .unread, .on, .off, .needsApproval: return true
        }
    }

    /// The line under the row's title.
    ///
    /// Here rather than in the view because it is the only part of the row's
    /// presentation with a right answer — the same split `PowerLabel` and
    /// `ClipboardPreview` already make.
    public var detail: String {
        switch self {
        case .unread, .on, .off:
            return "Opens CreativeNotch when you log in."
        case .needsApproval:
            return "macOS is holding this until you allow it in System Settings \u{203A} General \u{203A} Login Items."
        case .unavailable(let path):
            return "Only an installed copy can do this. This one is running from \(path)."
        }
    }
}
