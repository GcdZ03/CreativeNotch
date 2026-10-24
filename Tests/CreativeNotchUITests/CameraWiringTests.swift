import Foundation
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// The camera as `AppDelegate` and the switchboard wire it.
///
/// `CameraControllerTests` pins the controller on its own; these pin the legs
/// that reach it -- each was missing at one point, and each failure looked
/// fine from inside the controller.
@MainActor
struct CameraWiringTests {

    final class Log: @unchecked Sendable {
        var runCalls: [Bool] = []
        var teardowns = 0
    }

    private func makeDelegate() throws -> (AppDelegate, CameraController, Log) {
        let delegate = AppDelegate()
        delegate.shelfTrash = TestTrash.shelf
        delegate.preferencesDefaults = TestDefaults.isolated("camera-wiring")
        delegate.growthDelay = .zero
        delegate.shelfDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CreativeNotchCameraWiring-\(UUID().uuidString)")
        delegate.playChime = { _ in }
        delegate.install(metrics: NotchedDelegate.metrics)
        // Nothing here may reach real hardware or start a real subsystem.
        delegate.capture?.observer.readCurrentUse = { .none }
        delegate.clipboard?.poller.scheduleTimer = { _, _ in nil }
        delegate.clipboard?.poller.cancelTimer = { _ in }
        delegate.media?.supervisor.startHelper = {}
        delegate.media?.supervisor.stopHelper = {}

        let log = Log()
        let camera = try #require(delegate.camera)
        camera.authorizationStatus = { .authorized }
        camera.applyRunState = { log.runCalls.append($0) }
        camera.beginRecording = { _, _ in }
        camera.endRecording = {}
        camera.shutDownSession = { log.teardowns += 1 }
        camera.capturesDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CreativeNotchCaptures-\(UUID().uuidString)")
        return (delegate, camera, log)
    }

    /// **A photo reaches the shelf the delegate actually has.** The camera
    /// was built before the shelf existed and kept the `nil` it was handed,
    /// so every capture was saved and never listed.
    @Test func aPhotoReachesTheRealShelf() throws {
        let (delegate, camera, _) = try makeDelegate()
        let shelf = try #require(delegate.shelf)
        try FileManager.default.createDirectory(
            at: camera.capturesDirectory,
            withIntermediateDirectories: true
        )
        let photo = camera.capturesDirectory.appendingPathComponent("Photo.jpg")

        camera.didCapturePhoto(Data("a photo".utf8), to: photo)

        let item = try #require(shelf.items.first, "the capture never reached the shelf")
        #expect(item.url == photo)
        #expect(item.isOwned == false)
    }

    @Test func aClipReachesTheRealShelf() throws {
        let (delegate, camera, _) = try makeDelegate()
        let shelf = try #require(delegate.shelf)
        try FileManager.default.createDirectory(
            at: camera.capturesDirectory,
            withIntermediateDirectories: true
        )
        let clip = camera.capturesDirectory.appendingPathComponent("Clip.mov")
        try Data("a clip".utf8).write(to: clip)

        camera.didFinishRecording(clip)

        #expect(shelf.items.first?.url == clip, "the clip never reached the shelf")
    }

    /// **Locking the screen stops the preview.** The switchboard fanned the
    /// gate out to four modules and not this one, so a camera left open on
    /// the tab kept its light on behind the lock screen.
    @Test func lockingTheScreenReachesTheCamera() throws {
        let (delegate, camera, log) = try makeDelegate()
        camera.setTabVisible(true)
        #expect(log.runCalls.last == true)

        delegate.switchboard.setActivity(.locked)

        #expect(camera.shouldRun == false)
        #expect(log.runCalls.last == false)

        delegate.switchboard.setActivity(.active)
        #expect(camera.shouldRun)
    }

    /// **Quit tears the camera down**, recording or not. The stop list knew
    /// nothing about it, so quitting mid-take left a `.mov` with no index.
    @Test func terminatingShutsTheCameraDown() throws {
        let (delegate, camera, log) = try makeDelegate()
        // The fake output closes the file when the session is torn down, as
        // the real one does; without it quit waits out the whole timeout.
        var clip: (URL, MovieDelegate)?
        camera.beginRecording = { url, movie in clip = (url, movie) }
        camera.shutDownSession = {
            log.teardowns += 1
            if let (url, movie) = clip { movie.finish(url, error: nil) }
        }
        camera.setTabVisible(true)
        camera.startRecording()
        #expect(camera.shouldBadge)

        delegate.switchboard.stopAll()

        #expect(log.teardowns == 1)
        #expect(camera.shouldRun == false)
        #expect(camera.shouldBadge == false)
    }
}
