import Foundation
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// The login-item toggle.
///
/// **No test here reaches the real `SMAppService`.** A real `register()`
/// writes a record into the developer's Background Task Management database,
/// and it outlives the process — so a suite that made one would pass or fail
/// depending on whether it had ever been run before. Every seam is injected,
/// exactly as the media module never spawns a real helper.
@MainActor
struct LaunchAtLoginControllerTests {

    private static let installed = "/Applications/CreativeNotch.app"
    private static let devBuild = "/Users/someone/Github/CreativeNotch/dist/CreativeNotch.app"
    private static let dirs = ["/Applications"]

    private func makeController(
        path: String = installed,
        status: Int = 0
    ) -> LaunchAtLoginController {
        let controller = LaunchAtLoginController(
            bundlePath: path, installDirectories: Self.dirs
        )
        controller.readStatus = { status }
        controller.register = {}
        controller.unregister = {}
        return controller
    }

    // MARK: - The read that must not happen

    /// **The test this module exists to pass.** An uninstalled copy must not
    /// *call* the read, not merely discard its answer — the call itself
    /// repoints the system's record at this bundle
    /// (`docs/research/2026-09-19-launch-at-login-probe.md`, Q3).
    ///
    /// Asserting only that the state is `.unavailable` would pass against a
    /// controller that read the status first and then threw the answer away,
    /// which is precisely the bug.
    @Test func anUninstalledCopyNeverReadsTheStatus() {
        var reads = 0
        let controller = LaunchAtLoginController(
            bundlePath: Self.devBuild, installDirectories: Self.dirs
        )
        controller.readStatus = { reads += 1; return 1 }

        controller.refresh()

        #expect(reads == 0, "an uninstalled copy touched the service")
        #expect(controller.state == .unavailable(bundlePath: Self.devBuild))
    }

    /// Constructing one must touch nothing either — a controller built at
    /// launch would otherwise repoint the record before any window opened.
    ///
    /// This proves the *state* is provisional rather than read. It does not
    /// prove nothing was read: see the source scan below for why it cannot.
    @Test func constructingAControllerLeavesTheStateProvisional() {
        let controller = LaunchAtLoginController(
            bundlePath: Self.installed, installDirectories: Self.dirs
        )

        #expect(controller.state == .off, "the initial state was not provisional")
    }

    /// **Pinned by a source scan, because nothing else can reach it.**
    ///
    /// The seam catches an initialiser that reads through `readStatus`. It
    /// cannot catch one that calls `SMAppService.mainApp.status` *directly*:
    /// the spy is never consulted, and the real service answers about the
    /// test runner's own bundle — which reports off, the same value the
    /// provisional state has. That mutation was applied and every
    /// behavioural test in this file passed.
    ///
    /// So the rule is pinned where it is visible instead. The framework is
    /// named exactly three times, once per injected default, and an
    /// occurrence anywhere else — an initialiser, a convenience read, a
    /// "just this once" — is a call that bypasses the seam and therefore
    /// bypasses the eligibility rule the seam exists to enforce.
    ///
    /// Same shape as `PanelTabBarTests.theBodyRendersTheListItWasGiven`:
    /// where behaviour is unreachable, scan the source and say so.
    @Test func theServiceIsNamedOnlyInTheThreeInjectedDefaults() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/CreativeNotchUI/Startup/LaunchAtLoginController.swift")
        let text = try String(contentsOf: source, encoding: .utf8)

        // Code only: the doc comments discuss the framework by name.
        let code = text.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")

        #expect(code.components(separatedBy: "SMAppService").count - 1 == 3,
                "SMAppService is called somewhere other than the three injected defaults")
        #expect(code.contains("var readStatus: () -> Int = { SMAppService.mainApp.status.rawValue }"))
        #expect(code.contains("var register: () throws -> Void = { try SMAppService.mainApp.register() }"))
        #expect(code.contains("var unregister: () throws -> Void = { try SMAppService.mainApp.unregister() }"))
    }

    /// And the suite as a whole never reaches the real service.
    ///
    /// A real `register()` writes a record that outlives the process, so one
    /// test that made one would change every later run on that machine.
    ///
    /// This file is the one exclusion, and deliberately: it names the
    /// framework only inside the string literals the scan above compares
    /// against, never as a call. Excluding it by name rather than loosening
    /// the match keeps the check exact for all 60-odd other files.
    @Test func noTestInThisRepoTouchesTheRealService() throws {
        let tests = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let enumerator = try #require(
            FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil)
        )
        let thisFile = URL(fileURLWithPath: #filePath).lastPathComponent
        for case let url as URL in enumerator
        where url.pathExtension == "swift" && url.lastPathComponent != thisFile {
            let text = try String(contentsOf: url, encoding: .utf8)
            let code = text.split(separator: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            #expect(!code.contains("SMAppService"),
                    "\(url.lastPathComponent) reaches the real login-item service")
        }
    }

    /// And an uninstalled copy must not write, however the row is driven.
    @Test func anUninstalledCopyNeverRegisters() {
        var registrations = 0
        let controller = LaunchAtLoginController(
            bundlePath: Self.devBuild, installDirectories: Self.dirs
        )
        controller.readStatus = { 1 }
        controller.register = { registrations += 1 }

        controller.setEnabled(true)

        #expect(registrations == 0)
        #expect(controller.state == .unavailable(bundlePath: Self.devBuild))
    }

    // MARK: - An installed copy

    @Test func anInstalledCopyReadsWhatTheSystemSays() {
        #expect(makeController(status: 1).stateAfterRefresh == .on)
        #expect(makeController(status: 0).stateAfterRefresh == .off)
        #expect(makeController(status: 2).stateAfterRefresh == .needsApproval)
    }

    @Test func switchingOnRegistersAndThenRereads() {
        var registrations = 0
        var status = 0
        let controller = makeController()
        controller.readStatus = { status }
        controller.register = { registrations += 1; status = 1 }

        controller.setEnabled(true)

        #expect(registrations == 1)
        #expect(controller.state == .on)
    }

    @Test func switchingOffUnregistersAndThenRereads() {
        var removals = 0
        var status = 1
        let controller = makeController()
        controller.readStatus = { status }
        controller.unregister = { removals += 1; status = 0 }

        controller.setEnabled(false)

        #expect(removals == 1)
        #expect(controller.state == .off)
    }

    /// **The honesty rule.** A registration that throws leaves the switch
    /// showing what the system says — off — rather than what was asked for.
    /// A stored `Bool` would show `on` over nothing at all, which is the
    /// exact inversion the Preferences module exists to prevent, arrived at
    /// from the opposite direction.
    @Test func aFailedRegistrationLeavesTheSwitchOff() {
        struct Refused: Error {}
        let controller = makeController(status: 0)
        controller.register = { throw Refused() }

        controller.setEnabled(true)

        #expect(controller.state == .off)
    }

    /// The system is the source of truth, so a change made in System
    /// Settings shows up on the next read without anything having told us.
    @Test func aRegistrationRemovedElsewhereShowsUpOnRefresh() {
        var status = 1
        let controller = makeController()
        controller.readStatus = { status }
        controller.refresh()
        #expect(controller.state == .on)

        status = 0            // the user switched it off in System Settings
        controller.refresh()

        #expect(controller.state == .off)
    }
}

private extension LaunchAtLoginController {
    var stateAfterRefresh: LaunchAtLoginState {
        refresh()
        return state
    }
}
