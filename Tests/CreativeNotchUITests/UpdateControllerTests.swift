import Foundation
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// The updater's controller over fake seams (2026-10-24): when it asks,
/// what it remembers, what it reports, and what "Update Now" does. The
/// clock is a fixed date the test moves by hand.
@MainActor
struct UpdateControllerTests {

    final class Clock {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    final class Effects {
        var relaunched: [URL] = []
        var terminated = 0
        var opened: [URL] = []
        var copied: [String] = []
    }

    let clock = Clock()
    let effects = Effects()
    let defaults = TestDefaults.isolated("updates")
    let root = UpdateFakes.temporaryDirectory("controller")
    var installs: URL { root.appendingPathComponent("Applications", isDirectory: true) }
    var bundle: URL { installs.appendingPathComponent("CreativeNotch.app", isDirectory: true) }

    private func make(
        _ fetcher: FakeReleaseFetcher = FakeReleaseFetcher([]),
        installer: any UpdateInstalling = FakeInstaller(),
        version: String = "0.12.0",
        installed: Bool = true,
        writable: Bool = true
    ) -> UpdateController {
        let environment = UpdateEnvironment(
            fetcher: fetcher,
            installer: installer,
            bundleURL: bundle,
            installDirectories: installed ? [installs.path] : [],
            isWritable: { _ in writable },
            relaunch: { [effects] in effects.relaunched.append($0) },
            terminate: { [effects] in effects.terminated += 1 },
            openURL: { [effects] in effects.opened.append($0) },
            copy: { [effects] in effects.copied.append($0) },
            now: { [clock] in clock.now },
            currentVersion: version
        )
        return UpdateController(environment: environment, defaults: defaults)
    }

    private func settle(_ controller: UpdateController) async {
        await controller.checkTask?.value
        await controller.installTask?.value
    }

    // MARK: - Checking

    @Test func aLaunchCheckFindsANewerRelease() async {
        let fetcher = FakeReleaseFetcher([FakeReleaseFetcher.ok()])
        let controller = make(fetcher)
        #expect(controller.check(.launch))
        #expect(controller.status == .checking)
        await settle(controller)
        #expect(controller.status == .available(UpdateFakes.release()))
        #expect(await fetcher.count == 1)

        let record = PreferencesStore(defaults: defaults).loadUpdateRecord()
        #expect(record.lastCheck == clock.now)
        #expect(record.etag == #"W/"1""#)
        #expect(record.release == UpdateFakes.release())
    }

    @Test func theSameVersionIsUpToDate() async {
        let controller = make(FakeReleaseFetcher([FakeReleaseFetcher.ok("v0.12.0")]))
        controller.check(.launch)
        await settle(controller)
        #expect(controller.status == .upToDate(checkedAt: clock.now))
    }

    @Test func theRequestCarriesTheUserAgent() async throws {
        let fetcher = FakeReleaseFetcher([FakeReleaseFetcher.ok()])
        let controller = make(fetcher)
        controller.check(.launch)
        await settle(controller)
        let headers = try #require(await fetcher.requests.first)
        #expect(headers["User-Agent"] == "CreativeNotch/0.12.0")
        #expect(headers["If-None-Match"] == nil, "nothing cached yet, so no ETag")
    }

    /// The second check sends the ETag back; the 304 keeps the cached
    /// release and moves only the date.
    @Test func anUnchangedReleaseIsA304() async throws {
        let fetcher = FakeReleaseFetcher([FakeReleaseFetcher.ok(), FakeReleaseFetcher.notModified])
        let controller = make(fetcher)
        controller.check(.launch)
        await settle(controller)
        clock.now += 25 * 3_600
        controller.check(.wake)
        await settle(controller)
        #expect(await fetcher.requests.last?["If-None-Match"] == #"W/"1""#)
        #expect(controller.status == .available(UpdateFakes.release()))
        #expect(PreferencesStore(defaults: defaults).loadUpdateRecord().lastCheck == clock.now)
    }

    @Test func wakeAndSettingsAreThrottled() async {
        let fetcher = FakeReleaseFetcher([FakeReleaseFetcher.ok(), FakeReleaseFetcher.notModified])
        let controller = make(fetcher)
        controller.check(.launch)
        await settle(controller)

        clock.now += 3_600
        #expect(!controller.check(.wake))
        #expect(!controller.check(.settingsOpened))
        #expect(await fetcher.count == 1)

        clock.now += 24 * 3_600
        #expect(controller.check(.settingsOpened))
        await settle(controller)
        #expect(await fetcher.count == 2)
    }

    @Test func automaticOffLeavesOnlyTheManualCheck() async {
        let fetcher = FakeReleaseFetcher([FakeReleaseFetcher.ok()])
        let controller = make(fetcher)
        controller.setAutomatic(false)
        #expect(!PreferencesStore(defaults: defaults).checksForUpdatesAutomatically)
        #expect(!controller.check(.launch))
        #expect(!controller.check(.wake))
        #expect(!controller.check(.settingsOpened))
        #expect(await fetcher.count == 0)
        #expect(controller.check(.manual))
        await settle(controller)
        #expect(await fetcher.count == 1)
    }

    @Test func theToggleIsReadFromTheStore() {
        PreferencesStore(defaults: defaults).setChecksForUpdatesAutomatically(false)
        #expect(!make().automatic)
    }

    /// A check already running is not started twice.
    @Test func oneCheckAtATime() async {
        let fetcher = FakeReleaseFetcher([FakeReleaseFetcher.ok(), FakeReleaseFetcher.ok()])
        let controller = make(fetcher)
        #expect(controller.check(.launch))
        #expect(!controller.check(.manual))
        await settle(controller)
        #expect(await fetcher.count == 1)
    }

    // MARK: - Failing quietly, or not

    /// Nobody asked, so nobody is told: an automatic check that fails
    /// leaves the status where it was.
    @Test(arguments: [nil, FakeReleaseFetcher.rateLimited] as [HTTPReply?])
    func anAutomaticFailureIsQuiet(_ reply: HTTPReply?) async {
        let controller = make(FakeReleaseFetcher([reply]))
        controller.check(.launch)
        await settle(controller)
        #expect(controller.status == .notChecked)
        #expect(PreferencesStore(defaults: defaults).loadUpdateRecord().lastCheck == nil, "a failure is not a check")
    }

    @Test func anAutomaticFailureKeepsAKnownUpdate() async {
        let fetcher = FakeReleaseFetcher([FakeReleaseFetcher.ok(), nil])
        let controller = make(fetcher)
        controller.check(.launch)
        await settle(controller)
        clock.now += 25 * 3_600
        controller.check(.wake)
        await settle(controller)
        #expect(controller.status == .available(UpdateFakes.release()))
    }

    @Test func aManualFailureIsReported() async {
        let controller = make(FakeReleaseFetcher([nil, FakeReleaseFetcher.rateLimited]))
        controller.check(.manual)
        await settle(controller)
        #expect(controller.status == .checkFailed(.offline))
        controller.check(.manual)
        await settle(controller)
        #expect(controller.status == .checkFailed(.rateLimited))
    }

    /// Asked for while an automatic check is in flight, the answer is
    /// reported as if the manual one had run.
    @Test func aManualCheckJoiningAnAutomaticOneReportsItsFailure() async {
        let controller = make(FakeReleaseFetcher([nil]))
        controller.check(.launch)
        controller.check(.manual)
        await settle(controller)
        #expect(controller.status == .checkFailed(.offline))
    }

    // MARK: - Restoring

    @Test func aRememberedReleaseIsOfferedAtLaunch() throws {
        PreferencesStore(defaults: defaults).saveUpdateRecord(
            UpdateRecord(lastCheck: clock.now, etag: "e", release: UpdateFakes.release())
        )
        #expect(make().status == .available(UpdateFakes.release()))
        #expect(make(version: "0.13.0").status == .upToDate(checkedAt: clock.now))
    }

    // MARK: - Installing

    private func offered(installer: any UpdateInstalling = FakeInstaller(), installed: Bool = true, writable: Bool = true) async -> UpdateController {
        let controller = make(FakeReleaseFetcher([FakeReleaseFetcher.ok()]), installer: installer, installed: installed, writable: writable)
        controller.check(.launch)
        await settle(controller)
        return controller
    }

    @Test func updateNowInstallsThenRelaunchesAndQuits() async {
        let installer = FakeInstaller()
        let controller = await offered(installer: installer)
        await installer.setProbe { await MainActor.run { controller.status } }
        #expect(controller.eligibility == .selfUpdate)

        controller.installUpdate()
        #expect(controller.status == .installing(UpdateFakes.release(), .downloading))
        await settle(controller)

        let release = UpdateFakes.release()
        #expect(await installer.observed == [
            .installing(release, .downloading), .installing(release, .verifying), .installing(release, .installing),
        ])
        #expect(await installer.installs.map(\.1) == [bundle])
        #expect(controller.status == .relaunching(release))
        #expect(effects.relaunched == [bundle])
        #expect(effects.terminated == 1)
    }

    @Test func aFailedInstallSaysWhyAndNeitherRelaunchesNorQuits() async {
        let controller = await offered(installer: FakeInstaller(failure: .checksumMismatch))
        controller.installUpdate()
        await settle(controller)
        #expect(controller.status == .installFailed(UpdateFakes.release(), .checksumMismatch))
        #expect(effects.relaunched.isEmpty)
        #expect(effects.terminated == 0)
        // And it can be tried again.
        #expect(controller.status.installableRelease == UpdateFakes.release())
    }

    /// A dev build is told, never replaced.
    @Test func aDevBuildNeverReplacesItself() async {
        let installer = FakeInstaller()
        let controller = await offered(installer: installer, installed: false)
        #expect(controller.eligibility == .devBuild(bundlePath: bundle.path))
        controller.installUpdate()
        await settle(controller)
        #expect(await installer.installs.isEmpty)
        #expect(controller.status == .available(UpdateFakes.release()))
        #expect(effects.terminated == 0)
    }

    @Test func anUnwritableInstallShowsTheCommandInstead() async {
        let installer = FakeInstaller()
        let controller = await offered(installer: installer, writable: false)
        #expect(controller.eligibility == .needsAdmin(directory: installs.path))
        controller.installUpdate()
        await settle(controller)
        #expect(await installer.installs.isEmpty)
        controller.copyInstallCommand()
        #expect(effects.copied == [UpdateInstallEligibility.installCommand])
    }

    @Test func nothingToInstallWithoutAnOffer() async {
        let installer = FakeInstaller()
        let controller = make(installer: installer)
        controller.installUpdate()
        await settle(controller)
        #expect(await installer.installs.isEmpty)
        #expect(controller.status == .notChecked)
    }

    /// No check starts while an install runs.
    @Test func noCheckDuringAnInstall() async {
        let fetcher = FakeReleaseFetcher([FakeReleaseFetcher.ok(), FakeReleaseFetcher.ok()])
        let controller = make(fetcher)
        controller.check(.launch)
        await settle(controller)
        controller.installUpdate()
        #expect(!controller.check(.manual))
        await settle(controller)
        #expect(await fetcher.count == 1)
    }

    @Test func releaseNotesOpenTheReleasePage() async {
        let controller = await offered()
        controller.openReleaseNotes()
        #expect(effects.opened == [UpdateFakes.notes])
    }

    @Test func noReleaseNoNotes() {
        let controller = make()
        controller.openReleaseNotes()
        #expect(effects.opened.isEmpty)
    }

    // MARK: - Relaunch

    /// The relaunch helper's script, run for real with `touch` standing in
    /// for `open`, against a pid that has already exited and a path with a
    /// space in it: it must wait, then hand the path through unmangled.
    @Test func theRelaunchScriptOpensTheBundleItWasGiven() async throws {
        let target = root.appendingPathComponent("Has Space/CreativeNotch.app")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let arguments = UpdateRelaunch.arguments(bundlePath: target.path, waitingFor: 999_999, opener: "/usr/bin/touch")
        #expect(arguments.first == "-c")
        let status = await ProcessToolRunner().run("/bin/sh", arguments)
        #expect(status == 0)
        #expect(FileManager.default.fileExists(atPath: target.path))
    }

    @Test func theRealRelaunchUsesOpen() {
        let arguments = UpdateRelaunch.arguments(bundlePath: "/Applications/CreativeNotch.app", waitingFor: 42)
        #expect(arguments.contains("/Applications/CreativeNotch.app"))
        #expect(arguments.contains("42"))
        #expect(arguments.last == "/usr/bin/open")
        #expect(arguments[1].hasPrefix("sleep 1;"))
    }
}
