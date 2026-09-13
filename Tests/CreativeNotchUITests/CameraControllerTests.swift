import AVFoundation
import Foundation
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// The camera's lifecycle.
///
/// **No test here builds a real capture graph.** `swift test` produces a
/// bundle with no Info.plist usage description, and Apple's documented
/// response to constructing a session without one is termination -- so
/// `applyRunState` is injected and what is asserted is the decision, not the
/// hardware. The decision itself is pure and lives in `CameraRunReason`, where
/// all sixteen input combinations are pinned.
@MainActor
struct CameraControllerTests {

    final class Log: @unchecked Sendable {
        var runCalls: [Bool] = []
        var recordingStarts = 0
        var recordingStops = 0
    }

    private func makeController() -> (CameraController, Log) {
        let log = Log()
        let controller = CameraController(shelf: nil)
        controller.authorizationStatus = { .authorized }
        controller.applyRunState = { log.runCalls.append($0) }
        controller.beginRecording = { _, _ in log.recordingStarts += 1 }
        controller.endRecording = { log.recordingStops += 1 }
        return (controller, log)
    }

    // MARK: - The ordinary path

    @Test func openingTheTabStartsTheSession() {
        let (controller, log) = makeController()

        controller.setTabVisible(true)

        #expect(controller.shouldRun)
        #expect(controller.shouldPreview)
        #expect(log.runCalls.last == true)
        #expect(controller.state == .previewing)
    }

    @Test func leavingTheTabStopsTheSession() {
        let (controller, log) = makeController()
        controller.setTabVisible(true)
        #expect(log.runCalls.last == true)

        controller.setTabVisible(false)

        #expect(controller.shouldRun == false)
        #expect(log.runCalls.last == false)
        #expect(controller.state == .idle)
    }

    /// The activity gate stops the preview, like every other module's drawing.
    @Test func lockingStopsThePreview() {
        let (controller, log) = makeController()
        controller.setTabVisible(true)

        controller.setActivity(.locked)

        #expect(controller.shouldRun == false)
        #expect(log.runCalls.last == false)
    }

    // MARK: - A denied grant is not a bug

    /// **A denied camera vends black frames, not an error.** Without reading
    /// the grant before building the graph, a refusal is indistinguishable
    /// from the app being broken.
    @Test func aDeniedGrantIsReportedRatherThanShownAsBlackFrames() {
        let (controller, log) = makeController()
        controller.authorizationStatus = { .denied }

        controller.setTabVisible(true)

        #expect(controller.state == .denied)
        #expect(log.runCalls.last == false, "the graph was built for a denied camera")
    }

    @Test func aRestrictedGrantIsTreatedTheSameWay() {
        let (controller, _) = makeController()
        controller.authorizationStatus = { .restricted }

        controller.setTabVisible(true)

        #expect(controller.state == .denied)
    }

    /// Not-yet-determined is NOT a refusal -- it is the state every new user
    /// is in, and treating it as denied would mean nobody is ever prompted.
    @Test func anUndeterminedGrantStillBuildsTheGraphSoThePromptCanAppear() {
        let (controller, log) = makeController()
        controller.authorizationStatus = { .notDetermined }

        controller.setTabVisible(true)

        #expect(controller.state != .denied)
        #expect(log.runCalls.last == true)
    }

    // MARK: - The Preferences leg

    /// **Switching the module off stops the session even mid-recording.** The
    /// switch is a stronger statement than the cursor moving.
    @Test func switchingTheModuleOffStopsEverything() {
        let (controller, log) = makeController()
        controller.setTabVisible(true)
        #expect(log.runCalls.last == true)

        controller.setEnabled(false)

        #expect(controller.shouldRun == false)
        #expect(controller.shouldPreview == false)
        #expect(controller.shouldBadge == false)
        #expect(log.runCalls.last == false)
    }

    @Test func reEnablingWithTheTabOpenStartsItAgain() {
        let (controller, log) = makeController()
        controller.setTabVisible(true)
        controller.setEnabled(false)

        controller.setEnabled(true)

        #expect(controller.shouldRun)
        #expect(log.runCalls.last == true)
    }

    /// Re-enabling with the tab closed must NOT start the camera. A module
    /// switched back on is not a request to open the lens.
    @Test func reEnablingWithTheTabClosedStartsNothing() {
        let (controller, log) = makeController()
        controller.setEnabled(false)

        controller.setEnabled(true)

        #expect(controller.shouldRun == false)
        #expect(log.runCalls.last == false)
    }

    // MARK: - Recording, and the exemption

    /// **Press record, click away: the take survives.** A stray cursor ending
    /// a deliberate recording is the failure the exemption exists to prevent.
    @Test func aRecordingSurvivesTheTabClosing() {
        let (controller, log) = makeController()
        controller.setTabVisible(true)
        controller.startRecording()
        #expect(log.recordingStarts == 1)

        controller.setTabVisible(false)

        #expect(controller.shouldRun, "the recording died with the panel")
        #expect(controller.shouldPreview == false, "nothing to draw on")
        #expect(log.runCalls.last == true)
    }

    /// And the exemption is honest: whenever the session outlives the panel,
    /// the ear says so.
    @Test func aRecordingThatOutlivesThePanelShowsInTheEar() {
        let (controller, _) = makeController()
        controller.setTabVisible(true)
        controller.startRecording()
        controller.setTabVisible(false)

        #expect(controller.shouldBadge)
    }

    /// A locked screen does not stop a recording either -- same split as the
    /// timer: the drawing is gated, the work is not.
    @Test func lockingDoesNotStopARecording() {
        let (controller, log) = makeController()
        controller.setTabVisible(true)
        controller.startRecording()

        controller.setActivity(.locked)

        #expect(controller.shouldRun)
        #expect(log.runCalls.last == true)
    }

    /// **But switching the module off does**, and it stops the recording
    /// first rather than leaving it orphaned. The switch is a stronger
    /// statement than the cursor moving.
    @Test func switchingTheModuleOffStopsARecordingInProgress() {
        let (controller, log) = makeController()
        controller.setTabVisible(true)
        controller.startRecording()
        #expect(controller.shouldRun)

        controller.setEnabled(false)

        #expect(log.recordingStops == 1, "the recording was left running")
        #expect(controller.shouldRun == false)
        #expect(controller.shouldBadge == false)
    }

    /// Starting twice must not start two recordings -- the shutter and the
    /// record button are both things people press twice.
    @Test func startingARecordingTwiceStartsOne() {
        let (controller, log) = makeController()
        controller.setTabVisible(true)

        controller.startRecording()
        controller.startRecording()

        #expect(log.recordingStarts == 1)
    }

    /// And stopping when nothing is recording is a no-op, so a switchboard leg
    /// that runs twice need not ask first.
    @Test func stoppingWhenNothingIsRecordingIsHarmless() {
        let (controller, log) = makeController()
        controller.setTabVisible(true)

        controller.stopRecording()

        #expect(log.recordingStops == 0)
    }

    // MARK: - Where captures go

    /// **Captures are REFERENCED, never copied into the shelf.**
    ///
    /// The shelf enforces its retention by moving files to the Trash -- seven
    /// days, twenty items. That is right for a copy it made of something
    /// dragged in, and catastrophic for the only copy of a photograph the user
    /// just took. Adding it as an owned copy would mean their photo is trashed
    /// next week, and the first version of this module did exactly that.
    @Test func aFinishedClipIsReferencedRatherThanCopiedIntoTheShelf() throws {
        let shelfDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CameraShelf-\(UUID().uuidString)")
        let shelf = try ShelfStore(directory: shelfDirectory)
        let controller = CameraController(shelf: shelf)

        let captures = FileManager.default.temporaryDirectory
            .appendingPathComponent("Captures-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
        let clip = captures.appendingPathComponent("Clip.mov")
        try Data("a clip".utf8).write(to: clip)

        controller.didFinishRecording(clip)

        let item = try #require(shelf.items.first)
        #expect(item.isOwned == false, "the shelf took ownership of a capture it will later trash")
        #expect(item.url == clip, "the capture was copied instead of referenced")
    }

    @Test func aPhotoIsReferencedRatherThanCopiedIntoTheShelf() throws {
        let shelfDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CameraShelf-\(UUID().uuidString)")
        let shelf = try ShelfStore(directory: shelfDirectory)
        let controller = CameraController(shelf: shelf)

        let captures = FileManager.default.temporaryDirectory
            .appendingPathComponent("Captures-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
        let photo = captures.appendingPathComponent("Photo.jpg")

        controller.didCapturePhoto(Data("a photo".utf8), to: photo)

        let item = try #require(shelf.items.first)
        #expect(item.isOwned == false)
        #expect(item.url == photo)
        #expect(FileManager.default.fileExists(atPath: photo.path), "the photo was never written")
    }

    /// And they land somewhere permanent by default, not in a temporary
    /// directory that a copy would then duplicate.
    @Test func capturesDefaultToThePicturesFolder() {
        let controller = CameraController(shelf: nil)
        #expect(controller.capturesDirectory.path.contains("Pictures"))
        #expect(controller.capturesDirectory.lastPathComponent == "CreativeNotch")
    }

    // MARK: - State is published

    @Test func stateChangesAreAnnouncedOnce() {
        let (controller, _) = makeController()
        var states: [CameraController.State] = []
        controller.onStateChange = { states.append($0) }

        controller.setTabVisible(true)
        controller.setTabVisible(true)   // no change
        controller.setTabVisible(false)

        #expect(states == [.previewing, .idle])
    }
}
