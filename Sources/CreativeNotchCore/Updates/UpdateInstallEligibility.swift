import Foundation

/// Whether this copy of the app may replace itself (2026-10-24).
///
/// Decided from the bundle's path and one writability answer, both handed
/// in, so the whole rule runs here with no filesystem of consequence.
public enum UpdateInstallEligibility: Equatable, Sendable {
    /// Installed, and this user can write where it is installed.
    case selfUpdate
    /// Running from anywhere but `/Applications` or `~/Applications` —
    /// `dist/`, DerivedData, a temp folder. It hears about updates and never
    /// replaces itself: the copy it would replace is a developer's build,
    /// which `dev.sh` deletes on its next run anyway.
    case devBuild(bundlePath: String)
    /// Installed somewhere this user cannot write. `install.sh` would reach
    /// for `sudo` here; the app does not — an app asking for an
    /// administrator password to replace itself is the shape of malware —
    /// so it shows the one-line install command instead.
    case needsAdmin(directory: String)

    /// The command Settings offers when the app cannot update itself: the
    /// README's installer line, which asks for `sudo` only if it must.
    public static let installCommand =
        "curl -fsSL https://raw.githubusercontent.com/GcdZ03/CreativeNotch/main/Scripts/install.sh | bash"

    /// The installed check is `LaunchAtLoginEligibility`'s, for its reasons:
    /// a whitelist of install folders compared by whole path, because the
    /// places a throwaway copy can run from cannot be enumerated.
    public static func resolve(
        bundlePath: String, installDirectories: [String], isWritable: Bool
    ) -> UpdateInstallEligibility {
        let installed = LaunchAtLoginEligibility.resolve(
            bundlePath: bundlePath, installDirectories: installDirectories
        )
        guard installed == .eligible else { return .devBuild(bundlePath: bundlePath) }
        guard isWritable else {
            return .needsAdmin(directory: (bundlePath as NSString).deletingLastPathComponent)
        }
        return .selfUpdate
    }

    public var canInstall: Bool { self == .selfUpdate }

    /// What Settings says in place of "Update Now", or `nil` when the
    /// button is there.
    public var note: String? {
        switch self {
        case .selfUpdate:
            return nil
        case .devBuild(let path):
            return String(localized: "This copy runs from \(path), so it won't replace itself. To install the update, run:", bundle: .creativeNotch)
        case .needsAdmin(let directory):
            return String(localized: "Updating needs an administrator to change \(directory), and CreativeNotch won't ask for your password. To install the update, run this in Terminal:", bundle: .creativeNotch)
        }
    }

    /// What Settings says with no update on offer: only a dev build says
    /// anything, so nobody is surprised later that it will not install one.
    public var idleNote: String? {
        guard case .devBuild(let path) = self else { return nil }
        return String(localized: "This copy runs from \(path), so it checks for updates but won't install them itself.", bundle: .creativeNotch)
    }
}

/// Where the swap puts things: beside the running bundle, hidden, and named
/// for this process.
///
/// Beside it so every rename stays on one volume — a rename across volumes
/// is a copy, and a copy can fail halfway. Named for the process like
/// `install.sh`'s `.$APP_NAME.previous.$$`, so two attempts never collide.
public struct UpdateSwapPaths: Equatable, Sendable {
    public let bundle: URL
    /// The running copy, moved aside until the new one is in place.
    public let backup: URL
    /// The new copy, moved beside the bundle before the swap begins.
    public let staging: URL

    public init(bundle: URL, pid: Int32) {
        let directory = bundle.deletingLastPathComponent()
        let name = bundle.lastPathComponent
        self.bundle = bundle
        backup = directory.appendingPathComponent(".\(name).previous.\(pid)", isDirectory: true)
        staging = directory.appendingPathComponent(".\(name).incoming.\(pid)", isDirectory: true)
    }
}

/// The last check on what was unpacked.
public enum UpdateBundleCheck {
    /// Whether the unpacked app's `CFBundleShortVersionString` is the
    /// release's version. A signed, checksummed archive of the wrong build
    /// is still the wrong build — the release workflow checks the same pair
    /// (`CoreInfo.version` against the tag) before it publishes.
    public static func matches(bundleVersion: String?, tag: String) -> Bool {
        guard let bundleVersion,
              let found = SemanticVersion(bundleVersion),
              let expected = SemanticVersion(tag) else { return false }
        return found == expected
    }
}
