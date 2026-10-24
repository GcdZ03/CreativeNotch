import AppKit
import SwiftUI
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// Renders Settings → Updates in four states into
/// `docs/assets/features/updates-<state>.png` (2026-10-24).
///
/// **Opt-in**, like `SettingsFeatureRenders`, so the normal suite never
/// rewrites files in the repo:
///
///     CREATIVENOTCH_RENDER_FEATURES=1 swift test --filter UpdateRenders
///
/// Through a real offscreen `NSWindow` and `cacheDisplay`, never ordered
/// front, because a grouped `Form` renders blank through `ImageRenderer`.
/// The controller is the real one over fake seams: nothing is fetched,
/// downloaded or installed, and the clock is fixed.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CREATIVENOTCH_RENDER_FEATURES"] == "1"))
struct UpdateRenders {

    private static var outputDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/CreativeNotchUITests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("docs/assets/features", isDirectory: true)
    }

    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Paths for the words on screen only. Eligibility reads them as
    /// strings, and with a fake installer nothing is ever moved, so neither
    /// needs to exist — and `/Applications` is never touched.
    private static let installed = URL(fileURLWithPath: "/Applications/CreativeNotch.app")
    private static let devBuild = URL(fileURLWithPath: "/Users/you/Developer/CreativeNotch/dist/CreativeNotch.app")

    private func controller(
        record: UpdateRecord, installed: Bool = true, installer: any UpdateInstalling = FakeInstaller()
    ) -> UpdateController {
        let defaults = TestDefaults.isolated("update-renders")
        PreferencesStore(defaults: defaults).saveUpdateRecord(record)
        let environment = UpdateEnvironment(
            fetcher: FakeReleaseFetcher([]),
            installer: installer,
            bundleURL: installed ? Self.installed : Self.devBuild,
            installDirectories: ["/Applications"],
            isWritable: { _ in true },
            relaunch: { _ in }, terminate: {}, openURL: { _ in }, copy: { _ in },
            now: { Self.now },
            currentVersion: "0.12.0"
        )
        return UpdateController(environment: environment, defaults: defaults)
    }

    private func render(_ controller: UpdateController, height: CGFloat, to name: String) throws {
        let size = NSSize(width: 520, height: height)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        let host = NSHostingView(rootView: Form { UpdatesSection(controller: controller) }.formStyle(.grouped))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: Self.outputDirectory, withIntermediateDirectories: true)
        try png.write(to: Self.outputDirectory.appendingPathComponent("updates-\(name).png"))
        window.close()
    }

    @Test func renderUpToDate() throws {
        let current = UpdateFakes.release("v0.12.0")
        let controller = controller(record: UpdateRecord(lastCheck: Self.now.addingTimeInterval(-2 * 3_600), etag: "e", release: current))
        #expect(controller.status == .upToDate(checkedAt: Self.now.addingTimeInterval(-2 * 3_600)))
        try render(controller, height: 300, to: "up-to-date")
    }

    @Test func renderUpdateAvailable() throws {
        let controller = controller(record: UpdateRecord(lastCheck: Self.now, etag: "e", release: UpdateFakes.release()))
        #expect(controller.status == .available(UpdateFakes.release()))
        #expect(controller.eligibility == .selfUpdate)
        try render(controller, height: 300, to: "available")
    }

    @Test func renderDownloading() async throws {
        let controller = controller(
            record: UpdateRecord(lastCheck: Self.now, etag: "e", release: UpdateFakes.release()),
            installer: HeldInstaller()
        )
        controller.installUpdate()
        // Let the installer report the first phase, then hold.
        for _ in 0..<20 where controller.status != .installing(UpdateFakes.release(), .downloading) {
            await Task.yield()
        }
        #expect(controller.status == .installing(UpdateFakes.release(), .downloading))
        try render(controller, height: 300, to: "downloading")
        controller.installTask?.cancel()
        await controller.installTask?.value
    }

    @Test func renderDevBuild() throws {
        let controller = controller(
            record: UpdateRecord(lastCheck: Self.now, etag: "e", release: UpdateFakes.release()), installed: false
        )
        #expect(controller.eligibility.canInstall == false)
        try render(controller, height: 360, to: "dev-build")
    }
}

/// Reports "downloading" and waits to be cancelled.
private struct HeldInstaller: UpdateInstalling {
    func install(
        _ release: Release, over bundle: URL, progress: @escaping @Sendable (UpdatePhase) async -> Void
    ) async throws(UpdateInstallFailure) {
        await progress(.downloading)
        try? await Task.sleep(for: .seconds(60))
        throw .downloadFailed
    }
}
