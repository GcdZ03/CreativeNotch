import Foundation
import Testing
@testable import CreativeNotchCore

/// Whether this copy may replace itself, where the swap puts things, and
/// what is persisted (2026-10-24).
struct UpdateInstallRulesTests {

    private static let installs = ["/Applications", "/Users/someone/Applications"]

    @Test func anInstalledWritableCopyUpdatesItself() {
        #expect(UpdateInstallEligibility.resolve(
            bundlePath: "/Applications/CreativeNotch.app", installDirectories: Self.installs, isWritable: true
        ) == .selfUpdate)
        #expect(UpdateInstallEligibility.resolve(
            bundlePath: "/Users/someone/Applications/CreativeNotch.app", installDirectories: Self.installs, isWritable: true
        ) == .selfUpdate)
    }

    /// A build in `dist/`, DerivedData or a temp folder only ever hears
    /// about the update: replacing it would replace a developer's build
    /// with a release, and `dev.sh` would delete the result anyway.
    @Test(arguments: [
        "/Users/someone/src/CreativeNotch/dist/CreativeNotch.app",
        "/private/var/folders/xx/T/CreativeNotch.app",
        "/Applications/Utilities/CreativeNotch.app",
        "/Applications.old/CreativeNotch.app",
    ])
    func aCopyOutsideTheInstallFoldersIsADevBuild(_ path: String) {
        #expect(UpdateInstallEligibility.resolve(
            bundlePath: path, installDirectories: Self.installs, isWritable: true
        ) == .devBuild(bundlePath: path))
    }

    /// No sudo, ever: an installed copy whose folder this user cannot write
    /// is told how to update instead.
    @Test func anUnwritableInstallNeedsAnAdministrator() {
        #expect(UpdateInstallEligibility.resolve(
            bundlePath: "/Applications/CreativeNotch.app", installDirectories: Self.installs, isWritable: false
        ) == .needsAdmin(directory: "/Applications"))
    }

    /// A dev build is a dev build whether or not its folder is writable.
    @Test func devBuildOutranksPermissions() {
        #expect(UpdateInstallEligibility.resolve(
            bundlePath: "/tmp/x/CreativeNotch.app", installDirectories: Self.installs, isWritable: false
        ) == .devBuild(bundlePath: "/tmp/x/CreativeNotch.app"))
    }

    @Test func onlyASelfUpdateCanInstall() {
        #expect(UpdateInstallEligibility.selfUpdate.canInstall)
        #expect(!UpdateInstallEligibility.devBuild(bundlePath: "/x").canInstall)
        #expect(!UpdateInstallEligibility.needsAdmin(directory: "/x").canInstall)
    }

    /// The notes Settings shows, naming the path or folder so the refusal
    /// can be read, and none for a copy that can update itself.
    @Test func theNotesNameWhereTheCopyIs() throws {
        #expect(UpdateInstallEligibility.selfUpdate.note == nil)
        let dev = try #require(UpdateInstallEligibility.devBuild(bundlePath: "/src/dist/CreativeNotch.app").note)
        #expect(dev.contains("/src/dist/CreativeNotch.app"))
        let admin = try #require(UpdateInstallEligibility.needsAdmin(directory: "/Applications").note)
        #expect(admin.contains("/Applications"))
        #expect(dev != admin)
    }

    /// With nothing on offer only a dev build says anything.
    @Test func onlyADevBuildHasAnIdleNote() throws {
        #expect(UpdateInstallEligibility.selfUpdate.idleNote == nil)
        #expect(UpdateInstallEligibility.needsAdmin(directory: "/Applications").idleNote == nil)
        let idle = try #require(UpdateInstallEligibility.devBuild(bundlePath: "/src/dist/CreativeNotch.app").idleNote)
        #expect(idle.contains("/src/dist/CreativeNotch.app"))
    }

    @Test func theInstallCommandIsOneLine() {
        let command = UpdateInstallEligibility.installCommand
        #expect(!command.contains("\n"))
        #expect(command.hasPrefix("curl -fsSL https://"))
        #expect(command.hasSuffix("| bash"))
        #expect(!command.contains("sudo"))
    }

    // MARK: - Swap paths

    /// Beside the bundle, hidden, and named for this process — the shape
    /// `install.sh` uses (`.$APP_NAME.previous.$$`) — so both renames stay
    /// on one volume and two attempts never share a name.
    @Test func theBackupAndStagingSitBesideTheBundle() {
        let bundle = URL(fileURLWithPath: "/Applications/CreativeNotch.app")
        let paths = UpdateSwapPaths(bundle: bundle, pid: 4242)
        #expect(paths.backup.path == "/Applications/.CreativeNotch.app.previous.4242")
        #expect(paths.staging.path == "/Applications/.CreativeNotch.app.incoming.4242")
        #expect(paths.bundle == bundle)
    }

    @Test func theInstallerUsesTheSameBackupName() throws {
        let script = try String(contentsOf: Self.repoRoot.appendingPathComponent("Scripts/install.sh"), encoding: .utf8)
        #expect(script.contains(#"BACKUP="$DEST/.$APP_NAME.previous.$$""#))
    }

    // MARK: - The bundle's own version

    @Test func theExtractedBundleMustBeTheReleasesVersion() {
        #expect(UpdateBundleCheck.matches(bundleVersion: "0.13.0", tag: "v0.13.0"))
        #expect(UpdateBundleCheck.matches(bundleVersion: "0.13", tag: "v0.13.0"))
        #expect(!UpdateBundleCheck.matches(bundleVersion: "0.12.0", tag: "v0.13.0"))
        #expect(!UpdateBundleCheck.matches(bundleVersion: nil, tag: "v0.13.0"))
        #expect(!UpdateBundleCheck.matches(bundleVersion: "0.13.0", tag: "nightly"))
    }

    // MARK: - Persistence

    private func isolated() -> UserDefaults {
        let name = "com.gcdz.creativenotch.update-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func automaticChecksShipOn() {
        let defaults = isolated()
        #expect(PreferencesStore(defaults: defaults).checksForUpdatesAutomatically)
        defaults.set("no", forKey: PreferenceKeys.updatesAutomatic)
        #expect(PreferencesStore(defaults: defaults).checksForUpdatesAutomatically, "a mistyped value reads as absent")
    }

    @Test func automaticChecksSwitchedOffSurviveAReload() {
        let defaults = isolated()
        PreferencesStore(defaults: defaults).setChecksForUpdatesAutomatically(false)
        #expect(!PreferencesStore(defaults: defaults).checksForUpdatesAutomatically)
    }

    @Test func theRecordRoundTrips() {
        let defaults = isolated()
        #expect(PreferencesStore(defaults: defaults).loadUpdateRecord() == UpdateRecord())
        let release = Release(
            tag: "v0.13.0",
            notesURL: URL(string: "https://github.com/GcdZ03/CreativeNotch/releases/tag/v0.13.0")!,
            archiveURL: URL(string: "https://github.com/GcdZ03/CreativeNotch/releases/download/v0.13.0/CreativeNotch-v0.13.0.tar.gz"),
            checksumURL: nil
        )
        let record = UpdateRecord(lastCheck: Date(timeIntervalSince1970: 1_800_000_000), etag: #"W/"e""#, release: release)
        PreferencesStore(defaults: defaults).saveUpdateRecord(record)
        #expect(PreferencesStore(defaults: defaults).loadUpdateRecord() == record)
    }

    /// Saving an empty record removes the keys rather than writing blanks.
    @Test func anEmptyRecordLeavesNoKeys() {
        let defaults = isolated()
        let store = PreferencesStore(defaults: defaults)
        store.saveUpdateRecord(UpdateRecord(lastCheck: Date(timeIntervalSince1970: 1), etag: "e", release: nil))
        store.saveUpdateRecord(UpdateRecord())
        #expect(defaults.object(forKey: PreferenceKeys.updatesLastCheck) == nil)
        #expect(defaults.object(forKey: PreferenceKeys.updatesETag) == nil)
        #expect(defaults.object(forKey: PreferenceKeys.updatesRelease) == nil)
    }

    /// Pinned by literal: a renamed key abandons what was stored.
    @Test func theKeysAreStable() {
        #expect(PreferenceKeys.updatesAutomatic == "updates.automatic")
        #expect(PreferenceKeys.updatesLastCheck == "updates.lastCheck")
        #expect(PreferenceKeys.updatesETag == "updates.etag")
        #expect(PreferenceKeys.updatesRelease == "updates.release")
    }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
