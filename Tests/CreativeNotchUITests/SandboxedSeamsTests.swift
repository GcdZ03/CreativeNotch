import AppKit
import Foundation
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// A bare `AppDelegate()` reaches none of the user's real data.
///
/// The shelf's folder, its Trash, the preferences domain and the captures
/// folder all default to a sandbox, and only `configureForRealLaunch()`
/// points them at the real locations. These tests are what make that safe
/// by construction rather than by every suite remembering to override four
/// properties: a regression to a real default fails here, before any suite
/// that forgot can open the real shelf or purge into the real Trash.
///
/// Nothing here *uses* a real location. The real values are asserted as
/// values -- the Trash by `isSystem`, never by moving a file with it.
@MainActor
struct SandboxedSeamsTests {

    private static var realApplicationSupport: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .standardizedFileURL.path
    }

    private static var temporary: String {
        FileManager.default.temporaryDirectory.standardizedFileURL.path
    }

    @Test func aFreshDelegateIsSandboxedThroughInstall() throws {
        let delegate = AppDelegate()
        delegate.growthDelay = .zero
        delegate.install(metrics: NotchedDelegate.metrics)

        let shelf = delegate.shelfDirectory.standardizedFileURL.path
        #expect(shelf.hasPrefix(Self.realApplicationSupport) == false)
        #expect(shelf.hasPrefix(Self.temporary))
        #expect(delegate.shelfDirectory != AppDelegate.realShelfDirectory)

        #expect(delegate.shelfTrash.isSystem == false)
        #expect(delegate.preferencesDefaults !== UserDefaults.standard)
        #expect(delegate.timerNotices is SilentTimerNotices)

        let camera = try #require(delegate.camera)
        #expect(camera.capturesDirectory == delegate.capturesDirectory)
        #expect(camera.capturesDirectory != CameraController.picturesCapturesDirectory)
        #expect(camera.capturesDirectory.standardizedFileURL.path.hasPrefix(Self.temporary))

        // Bluetooth: no IOBluetooth registration and no system prompt can
        // come from a delegate a test built.
        #expect(delegate.bluetoothSource is SandboxBluetoothSource)
        #expect(delegate.bluetoothAccess is SandboxBluetoothAccess)

        // Power (2026-10-28): no IOKit registration, and never the battery
        // of the Mac the suite runs on -- below 20% and discharging, a real
        // reading put a low-battery peek in front of an unrelated test.
        // Asked of the controller `install` built, not only of the seam, so
        // an `install` that builds its own `PowerObserver` fails here too.
        #expect(delegate.powerObserver is SandboxPowerObserver)
        let power = try #require(delegate.power)
        #expect(power.observer is SandboxPowerObserver)
        #expect(power.observer === delegate.powerObserver)

        // Capture and clipboard (2026-10-29): never the developer's real
        // microphone, camera or clipboard. Asked of what `install` built,
        // so an `install` that reaches past the seams fails here too.
        #expect(delegate.captureReading is SandboxCaptureReading)
        let clipboard = try #require(delegate.clipboard)
        #expect(clipboard.pasteboard === delegate.clipboardPasteboard)
        #expect(clipboard.pasteboard.name != NSPasteboard.general.name)
    }

    /// The capture indicator reads through the seam `install` was handed,
    /// with the camera this app's own preview holds, rather than through the
    /// observer's own default, which is the system read.
    @Test func theCaptureIndicatorReadsThroughTheSeam() throws {
        final class Reading: CaptureReading {
            var askedFor: [String?] = []
            func currentUse(ownCameraUID: String?) -> CaptureUse {
                askedFor.append(ownCameraUID)
                return CaptureUse(camera: true)
            }
        }
        let reading = Reading()
        let delegate = AppDelegate()
        delegate.growthDelay = .zero
        delegate.captureReading = reading
        delegate.install(metrics: NotchedDelegate.metrics)

        let observer = try #require(delegate.capture?.observer)
        observer.ownCameraUID = "front"
        #expect(observer.readCurrentUse() == CaptureUse(camera: true))
        #expect(reading.askedFor.last == "front")
    }

    /// Two delegates never share a sandbox, so one test's shelf cannot leak
    /// into another's.
    @Test func eachDelegateHasItsOwnSandbox() {
        let a = AppDelegate()
        let b = AppDelegate()
        #expect(a.shelfDirectory != b.shelfDirectory)
        #expect(a.capturesDirectory != b.capturesDirectory)
        #expect(a.preferencesDefaults !== b.preferencesDefaults)
    }

    /// Asserted without `install` and without using any of them: assigning
    /// the values touches nothing.
    @Test func theRealLaunchConfigurationPointsAtTheRealLocations() {
        let delegate = AppDelegate()
        delegate.configureForRealLaunch()

        #expect(delegate.preferencesDefaults === UserDefaults.standard)
        #expect(delegate.shelfTrash.isSystem)
        #expect(delegate.shelfDirectory == AppDelegate.realShelfDirectory)
        #expect(delegate.shelfDirectory.standardizedFileURL.path
            .hasPrefix(Self.realApplicationSupport))
        #expect(delegate.shelfDirectory.path.hasSuffix("CreativeNotch/Shelf"))
        #expect(delegate.capturesDirectory == CameraController.picturesCapturesDirectory)
        #expect(delegate.capturesDirectory.lastPathComponent == "CreativeNotch")
        // Constructing these registers nothing and prompts for nothing.
        #expect(delegate.bluetoothSource is IOBluetoothSource)
        #expect(delegate.bluetoothAccess is SystemBluetoothAccess)
        // Constructed, never started: building it registers nothing.
        #expect(delegate.powerObserver is PowerObserver)
        // Constructed, never used: building it touches no notification center.
        #expect(delegate.timerNotices is SystemTimerNotices)
        // Read only once the switchboard starts the capture and clipboard
        // modules.
        #expect(delegate.captureReading is SystemCaptureReading)
        #expect(delegate.clipboardPasteboard.name == NSPasteboard.general.name)
        // The motion the shipped app has (2026-10-29): every suite runs the
        // instant stand-ins, so without these a real launch that kept one
        // would lose its fade, slide or morph with CI still green.
        #expect(delegate.panelFader is AnimatedPanelFader)
        #expect(delegate.panelSlider is AnimatedPanelSlider)
        #expect(delegate.panelMorpher is AnimatedPanelMorpher)
        #expect(delegate.windowFocusWatcher is SystemWindowFocusWatcher)
        #expect(delegate.appMenuReader is SystemAppMenuReader)
    }

    /// Opening a shelf file and previewing it reach other apps and put a
    /// window on screen: a bare delegate's do neither, and only the real
    /// launch hands in `NSWorkspace` and Quick Look. Asserted as values --
    /// nothing is opened or previewed.
    @Test func aFreshDelegateNeitherOpensNorPreviewsShelfFiles() {
        let delegate = AppDelegate()
        #expect(delegate.shelfOpener.isSystem == false)
        #expect(delegate.shelfPreview.isSystem == false)
        #expect(delegate.shelfOpener.open(URL(fileURLWithPath: "/tmp/never-opened.txt")) == false)

        delegate.configureForRealLaunch()
        #expect(delegate.shelfOpener.isSystem)
        #expect(delegate.shelfPreview.isSystem)
        #expect(delegate.shelfPreview is ShelfQuickLook)
    }

    @Test func onlyTheSystemTrashSaysItIs() {
        #expect(ShelfTrash.system.isSystem)
        #expect(ShelfTrash.folder(FileManager.default.temporaryDirectory).isSystem == false)
        #expect(ShelfTrash { $0 }.isSystem == false)
    }

    /// `applicationDidFinishLaunching` cannot be driven from a test (see
    /// `theLaunchPathStartsSubsystemsOnlyThroughTheOneMethod`), so a source
    /// scan pins that it opts into the real locations before anything else,
    /// and that nothing else in the app does.
    @Test func onlyTheLaunchPathConfiguresTheRealLocations() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // .../Tests/CreativeNotchUITests
            .deletingLastPathComponent()   // .../Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Sources")
        let delegateFile = sources.appendingPathComponent("CreativeNotchUI/AppDelegate.swift")
        let text = try String(contentsOf: delegateFile, encoding: .utf8)

        let start = try #require(text.range(of: "public func applicationDidFinishLaunching"))
        let body = text[start.upperBound...]
        let firstCode = body.split(separator: "\n").dropFirst()
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("//") }
        #expect(firstCode == "configureForRealLaunch()")

        // Every line of code -- comments aside -- that calls it, anywhere in
        // the app's sources. The declaration is not a call.
        var calls: [String] = []
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let file = files?.nextObject() as? URL {
            guard file.pathExtension == "swift" else { continue }
            let source = try String(contentsOf: file, encoding: .utf8)
            for line in source.split(separator: "\n") {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard code.contains("configureForRealLaunch()"),
                      !code.hasPrefix("//"),
                      !code.contains("func configureForRealLaunch()") else { continue }
                calls.append("\(file.lastPathComponent): \(code)")
            }
        }
        #expect(calls == ["AppDelegate.swift: configureForRealLaunch()"])
    }
}
