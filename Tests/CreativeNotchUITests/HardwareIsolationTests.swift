import AppKit
import Testing
@testable import CreativeNotchUI

/// The test suite must never reach real hardware (2026-10-17).
///
/// Three camera tests opened the camera tab on the real controller without
/// stubbing its run step, and were safe only because the process exited
/// before the camera's background queue got going — measured: the system's
/// "camera in use" flag stayed off. The terminal running `swift test` holds
/// camera permission, so a slower run could have switched the camera on, and
/// a process without a camera usage description that does so is terminated.
/// Most tests that open the panel also called the real haptic API.
///
/// So both are now guarded in the app itself, not left to each test to
/// remember: the camera needs a usage description, which only the packaged
/// app's Info.plist has, and the haptic needs the packaged `.app`.
@MainActor
struct HardwareIsolationTests {

    // MARK: - The camera

    @Test func theCameraNeedsAUsageDescription() {
        #expect(!CameraController.mayUseCamera(nil))
        #expect(!CameraController.mayUseCamera([:]))
        #expect(!CameraController.mayUseCamera(["NSCameraUsageDescription": ""]))
        #expect(CameraController.mayUseCamera(["NSCameraUsageDescription": "Shows the camera in the notch."]))
    }

    /// `swift test` has no such description, so this process may not.
    @Test func thisTestProcessMayNotUseTheCamera() {
        #expect(!CameraController.mayUseCamera(Bundle.main.infoDictionary))
    }

    /// End to end on the real run step, nothing stubbed: asking it to run
    /// builds no capture graph, so no camera input is ever added.
    @Test func theRealRunStepBuildsNothingHere() {
        let camera = CameraController(shelf: nil)
        camera.applyRunState(true)
        camera.sessionQueue.sync {}
        #expect(camera.captureSession.inputs.isEmpty)
        #expect(!camera.captureSession.isRunning)
    }

    // MARK: - Haptics

    @Test func thisTestProcessIsNotThePackagedApp() {
        #expect(!HostProcess.isPackagedApp())
    }

    /// A real `.app` bundle on disk is recognised as one — the check is not
    /// simply "never".
    @Test func aRealAppBundleIsRecognised() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HostProcess-\(UUID().uuidString)/Probe.app/Contents")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "com.example.probe", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: root.appendingPathComponent("Info.plist"))
        let bundle = try #require(Bundle(url: root.deletingLastPathComponent()))
        #expect(HostProcess.isPackagedApp(bundle))
    }

    /// The delegate's real haptic does nothing outside the packaged app, so a
    /// test that opens the panel without stubbing it taps nobody's trackpad.
    @Test func theRealHapticIsInertHere() {
        #expect(!AppDelegate.hapticsReachHardware)
    }
}
