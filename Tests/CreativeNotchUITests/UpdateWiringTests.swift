import AppKit
import Foundation
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// Where the updater is reached from (2026-10-24): the launch, a wake, the
/// Settings window, and the menu bar — and that a delegate a test builds
/// reaches no network and can replace, relaunch or quit nothing.
@MainActor
struct UpdateWiringTests {

    // MARK: - Sandboxed by default

    @Test func aFreshDelegatesUpdaterIsSandboxed() {
        let delegate = AppDelegate()
        let environment = delegate.updates.environment
        #expect(environment.fetcher is InertReleaseFetcher)
        #expect(environment.installer is InertUpdateInstaller)
        // Not the running test binary, not /Applications: a path that is
        // not installed, so even a forced install would refuse.
        #expect(environment.bundleURL != Bundle.main.bundleURL)
        #expect(environment.bundleURL.standardizedFileURL.path
            .hasPrefix(FileManager.default.temporaryDirectory.standardizedFileURL.path))
        #expect(delegate.updates.eligibility.canInstall == false)
    }

    /// Asserted as values: building the real seams fetches nothing.
    @Test func theRealLaunchConfigurationPointsTheUpdaterAtGitHub() {
        let delegate = AppDelegate()
        delegate.configureForRealLaunch()
        let environment = delegate.updates.environment
        #expect(environment.fetcher is GitHubReleaseFetcher)
        #expect(environment.installer is UpdateInstaller)
        #expect(environment.bundleURL == Bundle.main.bundleURL)
        #expect(environment.currentVersion == CoreInfo.version)
        // `swift test` runs from no install folder, so even the real
        // configuration would only ever notify here.
        #expect(delegate.updates.eligibility.canInstall == false)
    }

    // MARK: - Triggers

    private func delegate(_ fetcher: FakeReleaseFetcher) -> AppDelegate {
        let delegate = NotchedDelegate.make()
        delegate.updates.environment.fetcher = fetcher
        return delegate
    }

    /// Unlocking — `SystemActivity` back to `.active` — checks, through the
    /// one activity observer the app already has.
    @Test func comingBackToTheMacChecks() async {
        let fetcher = FakeReleaseFetcher([FakeReleaseFetcher.ok()])
        let delegate = delegate(fetcher)
        delegate.activity.handle(.screenLocked)
        #expect(await fetcher.count == 0, "locking is not a reason to check")
        delegate.activity.handle(.screenUnlocked)
        await delegate.updates.checkTask?.value
        #expect(await fetcher.count == 1)
        #expect(delegate.updates.status == .available(UpdateFakes.release()))
    }

    /// The launch check runs after the subsystems start.
    @Test func theLaunchChecks() async {
        let fetcher = FakeReleaseFetcher([FakeReleaseFetcher.ok()])
        let delegate = delegate(fetcher)
        delegate.startSubsystems()
        delegate.checkForUpdatesAtLaunch()
        await delegate.updates.checkTask?.value
        #expect(await fetcher.count == 1)
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
    }

    /// The launch path asks through the one method, after `startSubsystems()`.
    @Test func theLaunchPathChecksAfterStartingSubsystems() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CreativeNotchUI/AppDelegate.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        let launch = try #require(text.range(of: "public func applicationDidFinishLaunching"))
        let body = text[launch.upperBound...]
        let start = try #require(body.range(of: "startSubsystems()"))
        let check = try #require(body.range(of: "checkForUpdatesAtLaunch()"))
        #expect(start.lowerBound < check.lowerBound)
    }

    @Test func showingSettingsChecks() async {
        let fetcher = FakeReleaseFetcher([FakeReleaseFetcher.ok()])
        let delegate = delegate(fetcher)
        let controller = PreferencesController(
            switchboard: delegate.switchboard, state: delegate.state,
            launchAtLogin: delegate.launchAtLogin, updates: delegate.updates, presenter: { _ in }
        )
        controller.show()
        await delegate.updates.checkTask?.value
        #expect(await fetcher.count == 1)
        // Shown again within the day: no second request.
        controller.show()
        await delegate.updates.checkTask?.value
        #expect(await fetcher.count == 1)
    }

    /// "Check for Updates…" checks now, past the throttle and the toggle,
    /// and opens Settings on the Updates section to show the answer.
    @Test func theMenusCheckIsManualAndShowsTheAnswer() async {
        let fetcher = FakeReleaseFetcher([FakeReleaseFetcher.ok(), FakeReleaseFetcher.notModified])
        let delegate = delegate(fetcher)
        var presented: [PreferencesSection?] = []
        delegate.presentPreferences = { presented.append($0) }
        delegate.updates.setAutomatic(false)

        delegate.checkForUpdatesFromMenu()
        await delegate.updates.checkTask?.value
        delegate.checkForUpdatesFromMenu()
        await delegate.updates.checkTask?.value

        #expect(await fetcher.count == 2)
        #expect(presented == [.updates, .updates])
    }

    // MARK: - The menu

    private func menuBar(update: String?, check: @escaping () -> Void = {}, install: @escaping () -> Void = {}) -> MenuBarController {
        MenuBarController(
            onShowPreferences: {}, onClearShelf: {}, shelfCount: { 0 },
            onClearClipboard: {}, clipboardCount: { 0 },
            onCheckForUpdates: check,
            availableUpdate: { update },
            onUpdate: install
        )
    }

    @Test func theMenuAlwaysOffersACheck() throws {
        var checked = 0
        let controller = menuBar(update: nil, check: { checked += 1 })
        let menu = controller.makeMenu()
        let item = try #require(menu.items.first { $0.title == "Check for Updates\u{2026}" })
        #expect(item.isHidden == false)
        _ = (item.target as AnyObject?)?.perform(item.action, with: item)
        #expect(checked == 1)
        withExtendedLifetime(controller) {}
    }

    @Test func theUpdateItemShowsOnlyWithAnUpdate() throws {
        var version: String?
        var updated = 0
        let controller = MenuBarController(
            onShowPreferences: {}, onClearShelf: {}, shelfCount: { 0 },
            onClearClipboard: {}, clipboardCount: { 0 },
            availableUpdate: { version }, onUpdate: { updated += 1 }
        )
        let menu = controller.makeMenu()
        let item = try #require(controller.updateItem)
        #expect(menu.items.contains(item))
        #expect(item.isHidden)

        version = "0.13.0"
        controller.menuWillOpen(menu)
        #expect(item.isHidden == false)
        #expect(item.title == "Update to v0.13.0\u{2026}")
        _ = (item.target as AnyObject?)?.perform(item.action, with: item)
        #expect(updated == 1)

        version = nil
        controller.menuWillOpen(menu)
        #expect(item.isHidden)
    }

    /// The delegate's menu answers from the updater's status.
    @Test func theDelegateOffersTheVersionTheUpdaterFound() async {
        let delegate = delegate(FakeReleaseFetcher([FakeReleaseFetcher.ok()]))
        #expect(delegate.menuAvailableUpdate == nil)
        delegate.updates.check(.manual)
        await delegate.updates.checkTask?.value
        #expect(delegate.menuAvailableUpdate == "0.13.0")
    }

    // MARK: - Settings

    @Test func theUpdatesSectionIsNotAModuleGroup() {
        #expect(!PreferencesSection.moduleGroups.contains(.updates))
        #expect(Set(PreferencesSection.moduleGroups + [.updates]) == Set(PreferencesSection.allCases))
        #expect(PreferencesSection.updates.title == "Updates")
    }
}
