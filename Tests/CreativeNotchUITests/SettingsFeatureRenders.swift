import AppKit
import SwiftUI
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// Renders the Settings rows for the timer's notification switch and
/// clipboard history's excluded apps into `docs/assets/features/`
/// (2026-10-24).
///
/// **Opt-in.** Runs only with `CREATIVENOTCH_RENDER_FEATURES=1`, so the
/// normal suite never rewrites files in the repo:
///
///     CREATIVENOTCH_RENDER_FEATURES=1 swift test --filter SettingsFeatureRenders
///
/// Through a real offscreen `NSWindow` and `cacheDisplay`, not
/// `ImageRenderer`: a grouped `Form` renders blank through `ImageRenderer`
/// (see `LaunchAtLoginControllerTests`). The window is never ordered front.
/// The controller is the real one over a sandboxed delegate; only the
/// notification authorization is set by hand, since asking macOS is exactly
/// what a test must not do.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CREATIVENOTCH_RENDER_FEATURES"] == "1"))
struct SettingsFeatureRenders {

    private static var outputDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/CreativeNotchUITests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("docs/assets/features", isDirectory: true)
    }

    private func makeController(
        authorization: TimerNoticeAuthorization,
        excluded: [String]
    ) -> (AppDelegate, PreferencesController) {
        let delegate = AppDelegate()
        delegate.shelfTrash = TestTrash.shelf
        delegate.growthDelay = .zero
        delegate.playChime = { _ in }
        delegate.announce = { _ in }
        delegate.screenDescriptors = { [] }
        delegate.install(metrics: NotchedDelegate.metrics)
        delegate.clipboard?.poller.scheduleTimer = { _, _ in nil }
        delegate.clipboard?.poller.cancelTimer = { _ in }
        delegate.state.onSetClipboardExcludedApps?(excluded)
        delegate.state.timerNoticeAuthorization = authorization
        let controller = PreferencesController(
            switchboard: delegate.switchboard,
            state: delegate.state,
            launchAtLogin: delegate.launchAtLogin,
            presenter: { _ in }
        )
        return (delegate, controller)
    }

    private func render(_ controller: PreferencesController, height: CGFloat, to name: String) throws {
        let size = NSSize(width: 520, height: height)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        let host = NSHostingView(rootView: PreferencesView(controller: controller, only: [.clipboard, .timer]))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // Two turns of the run loop let the grouped form's table lay out its
        // rows before the snapshot; without them the first render is empty.
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: Self.outputDirectory, withIntermediateDirectories: true)
        try png.write(to: Self.outputDirectory.appendingPathComponent("timer-notify-clip-exclude-\(name).png"))
        window.close()
    }

    /// A fresh install: nothing excluded, and macOS not yet asked.
    @Test func renderTheEmptyState() throws {
        let (delegate, controller) = makeController(authorization: .notDetermined, excluded: [])
        try render(controller, height: 420, to: "settings-empty")
        _ = delegate
    }

    /// Two apps excluded, notifications allowed: no note under the switch.
    @Test func renderTheActiveState() throws {
        let (delegate, controller) = makeController(
            authorization: .allowed, excluded: ["com.apple.Terminal", "com.apple.Passwords"]
        )
        try render(controller, height: 440, to: "settings-active")
        _ = delegate
    }

    /// Notifications refused in System Settings: the switch says it can do
    /// nothing, and offers the way there.
    @Test func renderTheDeniedState() throws {
        let (delegate, controller) = makeController(authorization: .denied, excluded: ["com.apple.Terminal"])
        try render(controller, height: 470, to: "settings-denied")
        _ = delegate
    }

    /// Allowed with the alert style at None (2026-10-25): notices only reach
    /// Notification Center, and the row says so with the same way there.
    @Test func renderTheBannersOffState() throws {
        let (delegate, controller) = makeController(authorization: .bannersOff, excluded: ["com.apple.Terminal"])
        try render(controller, height: 470, to: "settings-banners-off")
        _ = delegate
    }
}
