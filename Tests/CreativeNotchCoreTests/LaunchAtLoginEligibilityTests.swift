import Foundation
import Testing
@testable import CreativeNotchCore

/// Which copy of the app may touch the login-item service at all.
///
/// A status read repoints the system's record at the copy doing the reading
/// (`docs/research/2026-09-19-launch-at-login-probe.md`, Q3), so this
/// decides *before* the read, from the path alone.
struct LaunchAtLoginEligibilityTests {

    private let dirs = ["/Applications", "/Users/someone/Applications"]

    @Test func anAppInstalledInApplicationsMayAsk() {
        #expect(LaunchAtLoginEligibility.resolve(
            bundlePath: "/Applications/CreativeNotch.app",
            installDirectories: dirs) == .eligible)
        #expect(LaunchAtLoginEligibility.resolve(
            bundlePath: "/Users/someone/Applications/CreativeNotch.app",
            installDirectories: dirs) == .eligible)
    }

    /// The hazard this whole rule exists for: `dev.sh` builds here, and
    /// starts by deleting it.
    @Test func aDevBuildMayNotAsk() {
        #expect(LaunchAtLoginEligibility.resolve(
            bundlePath: "/Users/someone/Github/CreativeNotch/dist/CreativeNotch.app",
            installDirectories: dirs) == .notInstalled)
    }

    /// Directly inside, not merely underneath — otherwise a copy in
    /// `/Applications/Utilities` claims the record too.
    @Test func aNestedCopyIsNotInstalled() {
        #expect(LaunchAtLoginEligibility.resolve(
            bundlePath: "/Applications/Utilities/CreativeNotch.app",
            installDirectories: dirs) == .notInstalled)
    }

    /// A prefix match would accept this, which is why the rule is not one.
    @Test func aLookalikeDirectoryIsNotInstalled() {
        #expect(LaunchAtLoginEligibility.resolve(
            bundlePath: "/Applications.old/CreativeNotch.app",
            installDirectories: dirs) == .notInstalled)
    }

    /// Trailing slashes come off some paths and not others; neither
    /// spelling may change the answer.
    @Test func aTrailingSlashChangesNothing() {
        #expect(LaunchAtLoginEligibility.resolve(
            bundlePath: "/Applications/CreativeNotch.app/",
            installDirectories: dirs) == .eligible)
    }

    /// A `/./` component is noise and must not change the answer.
    ///
    /// Named for what it asserts. It previously claimed to be about
    /// `/private/tmp` versus `/tmp`, which is true of `standardizingPath`
    /// but is not what the assertion exercises.
    @Test func aDotComponentChangesNothing() {
        #expect(LaunchAtLoginEligibility.resolve(
            bundlePath: "/Applications/./CreativeNotch.app",
            installDirectories: dirs) == .eligible)
    }

    /// **The one input that resolved eligible when it must not.**
    ///
    /// `standardizingPath` removes `..` lexically, so this collapses to
    /// `/Applications/CreativeNotch.app` — while `/tmp` is a symlink to
    /// `/private/tmp`, making the real parent `/private/Applications`. A
    /// path that has to be resolved against the filesystem to be judged is
    /// one this function refuses outright.
    @Test func aPathThatClimbsOutOfASymlinkIsRefused() {
        #expect(LaunchAtLoginEligibility.resolve(
            bundlePath: "/tmp/../Applications/CreativeNotch.app",
            installDirectories: dirs) == .notInstalled)
    }

    /// And the refusal is on the component, not the spelling: a directory
    /// legitimately named `..something` is not affected.
    @Test func aFilenameContainingDotsIsNotRefused() {
        #expect(LaunchAtLoginEligibility.resolve(
            bundlePath: "/Applications/..Creative..Notch.app",
            installDirectories: dirs) == .eligible)
    }

    // MARK: - Two spellings of one directory

    /// A symlinked install directory is still the install directory.
    ///
    /// Deterministic on any volume, unlike a case-only difference, which
    /// only demonstrates anything on a case-insensitive one. The strings
    /// disagree here — the bundle's parent is the real directory, the
    /// whitelist holds the link — so this can only pass through the
    /// identity comparison.
    @Test func aSymlinkedInstallDirectoryIsTheSameDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cn-eligibility-\(UUID().uuidString)")
        let real = root.appendingPathComponent("Real")
        let link = root.appendingPathComponent("Link")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let bundle = real.appendingPathComponent("CreativeNotch.app").path
        #expect(LaunchAtLoginEligibility.resolve(
            bundlePath: bundle, installDirectories: [link.path]) == .eligible)
    }

    /// And identity is not a licence to accept a *different* directory that
    /// happens to exist next door.
    @Test func twoRealDirectoriesAreNotOneDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cn-eligibility-\(UUID().uuidString)")
        let a = root.appendingPathComponent("A")
        let b = root.appendingPathComponent("B")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(LaunchAtLoginEligibility.resolve(
            bundlePath: a.appendingPathComponent("CreativeNotch.app").path,
            installDirectories: [b.path]) == .notInstalled)
    }

    /// A whitelist entry that does not exist cannot match anything, and must
    /// not throw or crash on the way to saying so.
    @Test func aMissingInstallDirectoryMatchesNothing() {
        #expect(LaunchAtLoginEligibility.resolve(
            bundlePath: "/Users/someone/dist/CreativeNotch.app",
            installDirectories: ["/no/such/directory/anywhere"]) == .notInstalled)
    }

    /// Pinned by equality, not by `contains`.
    ///
    /// With two `contains` assertions, **adding** `/tmp` and `~/Downloads`
    /// to the whitelist passed — which is the exact class of bug this
    /// module exists to prevent, since every extra directory is another
    /// throwaway location allowed to seize the login-item record.
    @Test func theDefaultDirectoriesAreExactlyApplicationsAndTheUsersOwn() {
        #expect(LaunchAtLoginEligibility.defaultInstallDirectories
                == ["/Applications", NSHomeDirectory() + "/Applications"])
    }
}

/// What the row shows, from the raw `SMAppService.Status` value.
struct LaunchAtLoginStateTests {

    @Test func enabledIsOn() {
        #expect(LaunchAtLoginState.from(rawStatus: 1) == .on)
    }

    /// Both "off" values display the same. They differ in the record — no
    /// record ever, versus a disabled tombstone — and nothing in the UI acts
    /// on that difference, so nothing here pretends to.
    @Test func bothOffValuesAreOff() {
        #expect(LaunchAtLoginState.from(rawStatus: 0) == .off)
        #expect(LaunchAtLoginState.from(rawStatus: 3) == .off)
    }

    @Test func requiresApprovalIsItsOwnState() {
        #expect(LaunchAtLoginState.from(rawStatus: 2) == .needsApproval)
    }

    /// A value Apple adds later must read as off, never as on: a switch
    /// claiming a registration nobody made is the one direction this module
    /// must never fail in.
    @Test func anUnknownValueIsOff() {
        #expect(LaunchAtLoginState.from(rawStatus: 99) == .off)
        #expect(LaunchAtLoginState.from(rawStatus: -1) == .off)
    }
}

/// The row's presentation, which lives in Core because a SwiftUI body is not
/// reachable from a test.
struct LaunchAtLoginPresentationTests {

    /// Only a registration the system confirmed reads as on.
    @Test func onlyOnIsOn() {
        #expect(LaunchAtLoginState.on.isOn)
        for state: LaunchAtLoginState in [.unread, .off, .needsApproval, .unavailable(bundlePath: "/x")] {
            #expect(state.isOn == false, "\(state) read as on")
        }
    }

    /// The second barrier in front of the eligibility rule: the controller
    /// refuses the call, and the row refuses the gesture.
    @Test func onlyAnUnavailableRowIsInoperable() {
        #expect(LaunchAtLoginState.unavailable(bundlePath: "/x").isOperable == false)
        for state: LaunchAtLoginState in [.unread, .on, .off, .needsApproval] {
            #expect(state.isOperable, "\(state) could not be operated")
        }
    }

    /// The path in `.unavailable` is the whole reason that case carries a
    /// payload: a refusal that does not say which copy is running is a
    /// mystery rather than a message.
    @Test func theUnavailableDetailNamesTheCopyThatIsRunning() {
        let detail = LaunchAtLoginState.unavailable(
            bundlePath: "/Users/someone/dist/CreativeNotch.app"
        ).detail
        #expect(detail.contains("/Users/someone/dist/CreativeNotch.app"))
    }

    /// A held registration must not read like a working one.
    @Test func needsApprovalSaysSoAndPointsAtSystemSettings() {
        let detail = LaunchAtLoginState.needsApproval.detail
        #expect(detail != LaunchAtLoginState.on.detail)
        #expect(detail.contains("Login Items"))
    }

    @Test func everyStateHasSomethingToSay() {
        for state: LaunchAtLoginState in [.unread, .on, .off, .needsApproval, .unavailable(bundlePath: "/x")] {
            #expect(!state.detail.isEmpty)
        }
    }
}
