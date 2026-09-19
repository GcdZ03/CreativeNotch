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

    /// `/private/tmp` and `/tmp` are the same directory, and `bundlePath`
    /// reports the resolved one. An install directory written either way
    /// has to match.
    @Test func equivalentSpellingsOfADirectoryMatch() {
        #expect(LaunchAtLoginEligibility.resolve(
            bundlePath: "/Applications/./CreativeNotch.app",
            installDirectories: dirs) == .eligible)
    }

    @Test func theDefaultDirectoriesAreApplicationsAndTheUsersOwn() {
        let defaults = LaunchAtLoginEligibility.defaultInstallDirectories
        #expect(defaults.contains("/Applications"))
        #expect(defaults.contains(NSHomeDirectory() + "/Applications"))
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
