import Foundation
import SwiftUI
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// The login-item toggle.
///
/// **No test here reaches the real service.** A real `register()` writes a
/// record into the developer's Background Task Management database, and it
/// outlives the process — so a suite that made one would pass or fail
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
        LaunchAtLoginController(
            bundlePath: path,
            installDirectories: Self.dirs,
            readStatus: { status },
            register: {},
            unregister: {}
        )
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
            bundlePath: Self.devBuild,
            installDirectories: Self.dirs,
            readStatus: { reads += 1; return 1 },
            register: {},
            unregister: {}
        )

        controller.refresh()

        #expect(reads == 0, "an uninstalled copy touched the service")
        #expect(controller.state == .unavailable(bundlePath: Self.devBuild))
    }

    /// Constructing one must touch nothing either — a controller built at
    /// launch would otherwise repoint the record before any window opened.
    ///
    /// `.unread` is what makes this assertable at all. An initialiser that
    /// *did* read would produce `.off` for an unregistered app, so while the
    /// unread seed and a real off were the same value, this could only ever
    /// pin the value and never the absence of the read.
    @Test func constructingAControllerReadsNothing() {
        var reads = 0
        let controller = LaunchAtLoginController(
            bundlePath: Self.installed,
            installDirectories: Self.dirs,
            readStatus: { reads += 1; return 1 },
            register: {},
            unregister: {}
        )

        #expect(reads == 0, "the initialiser read through the seam")
        #expect(controller.state == .unread,
                "the initialiser published an answer nobody asked for")
    }

    /// And an uninstalled copy must not write, however the row is driven.
    @Test func anUninstalledCopyNeverRegisters() {
        var registrations = 0
        let controller = LaunchAtLoginController(
            bundlePath: Self.devBuild,
            installDirectories: Self.dirs,
            readStatus: { 1 },
            register: { registrations += 1 },
            unregister: {}
        )

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

    /// Starts from `.unread` rather than from the old provisional `.off`.
    ///
    /// With `.off` as the seed, dropping the trailing `refresh()` from
    /// `setEnabled` left this green — the expected value and the untouched
    /// seed were the same, so the "AndThenRereads" half proved nothing.
    @Test func switchingOffUnregistersAndThenRereads() {
        var removals = 0
        var status = 1
        let controller = makeController()
        controller.readStatus = { status }
        controller.unregister = { removals += 1; status = 0 }
        #expect(controller.state == .unread)

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

    // MARK: - The row's binding

    /// A getter reading `!= .on` shows the switch backwards, and nothing
    /// else in the suite would notice: the row is a SwiftUI body, and a
    /// grouped `Form` renders blank through `ImageRenderer`.
    @Test func theSwitchReadsOnOnlyWhenTheSystemSaidOn() {
        let controller = makeController(status: 1)
        controller.refresh()
        #expect(LaunchAtLoginRow.binding(for: controller).wrappedValue)

        let off = makeController(status: 0)
        off.refresh()
        #expect(LaunchAtLoginRow.binding(for: off).wrappedValue == false)
    }

    /// And a setter calling `setEnabled(!$0)` would unregister when asked to
    /// register. One character, invisible everywhere else.
    @Test func theSwitchWritesInTheDirectionItWasMoved() {
        var registrations = 0
        var removals = 0
        let controller = makeController()
        controller.register = { registrations += 1 }
        controller.unregister = { removals += 1 }

        LaunchAtLoginRow.binding(for: controller).wrappedValue = true
        #expect((registrations, removals) == (1, 0))

        LaunchAtLoginRow.binding(for: controller).wrappedValue = false
        #expect((registrations, removals) == (1, 1))
    }

    /// The deep link is the only part of "open System Settings" with a right
    /// answer; `NSWorkspace.shared.open` is not seamed.
    @Test func theManualRouteHasAUsableDeepLink() throws {
        let url = try #require(LaunchAtLoginController.loginItemsSettingsURL)
        #expect(url.scheme == "x-apple.systempreferences")
        #expect(url.absoluteString.hasSuffix("com.apple.LoginItems-Settings.extension"))
    }

    // MARK: - Pinned by source scans, because nothing else can reach them

    /// **The seam is only a seam if nothing goes around it.**
    ///
    /// The injected closures catch an initialiser that reads through
    /// `readStatus`. They cannot catch one that calls the service directly:
    /// the spy is never consulted, and the real service answers about the
    /// test runner's own bundle. That mutation was applied and every
    /// behavioural test passed.
    ///
    /// Scanned across the **whole** `Sources/` tree, not just the
    /// controller: a one-line shim in a neighbouring file, called from
    /// `init`, defeated the single-file version of this check completely.
    ///
    /// Same shape as `PanelTabBarTests.theBodyRendersTheListItWasGiven`:
    /// where behaviour is unreachable, scan the source and say so.
    @Test func theServiceIsCalledOnlyInTheThreeInjectedSeams() throws {
        // Assembled rather than written out, so this file does not contain
        // the needle it is searching for -- which is what lets the scan
        // below cover every file including this one.
        let needle = "SMAppService" + ".mainApp"
        var total = 0

        for (name, text) in try Self.swiftSources(under: "Sources") {
            let hits = Self.callSites(of: needle, in: text)
            total += hits
            if hits > 0 {
                #expect(name == "LaunchAtLoginController.swift",
                        "\(name) calls the login-item service outside the seams")
            }
        }

        #expect(total == 3, "expected exactly three calls, one per seam, found \(total)")
    }

    /// And no test reaches the real service.
    ///
    /// This catches a direct call. The other route into the real service —
    /// constructing a controller with an *installed* path and leaving the
    /// default closures bound — is not catchable by any scan, because the
    /// needle appears nowhere. It is closed structurally instead: the only
    /// initialiser that binds the real service takes no path, and the one
    /// that takes a path requires all three seams. See
    /// `LaunchAtLoginController.init()`.
    @Test func noTestInThisRepoCallsTheRealService() throws {
        let needle = "SMAppService" + ".mainApp"
        for (name, text) in try Self.swiftSources(under: "Tests") {
            #expect(Self.callSites(of: needle, in: text) == 0,
                    "\(name) reaches the real login-item service")
        }
    }

    /// Every `.swift` file under a top-level directory, as (filename, text).
    private static func swiftSources(under directory: String) throws -> [(String, String)] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(directory)
        let enumerator = try #require(
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        )
        var found: [(String, String)] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            found.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
        }
        #expect(!found.isEmpty, "scanned \(directory) and found no sources")
        return found
    }

    /// Occurrences of `needle` that are neither commented out nor inside a
    /// string literal.
    ///
    /// Line comments and string contents are dropped rather than the whole
    /// line, so a trailing `// via SMAppService` no longer breaks the count
    /// and a doc comment can discuss the framework freely.
    private static func callSites(of needle: String, in text: String) -> Int {
        var total = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var code = Substring(line)
            if let comment = code.range(of: "//") { code = code[code.startIndex..<comment.lowerBound] }
            let outsideStrings = code
                .split(separator: "\"", omittingEmptySubsequences: false)
                .enumerated()
                .filter { $0.offset.isMultiple(of: 2) }
                .map(\.element)
                .joined()
            total += outsideStrings.components(separatedBy: needle).count - 1
        }
        return total
    }
}

private extension LaunchAtLoginController {
    var stateAfterRefresh: LaunchAtLoginState {
        refresh()
        return state
    }
}
