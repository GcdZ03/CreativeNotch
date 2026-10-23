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

    // MARK: - No camera

    /// **A configure that fails must say so.** `CameraSession.configure()`
    /// returning `false` used to be dropped on the floor, the tab went on
    /// reading `.previewing`, and the shutter sent `capturePhoto` to an output
    /// with no connection -- which AVFoundation answers with an exception.
    @Test func aFailedConfigureShowsUnavailableAndDisablesCapture() {
        let (controller, log) = makeController()
        var photoRequests = 0
        controller.capturePhoto = { _ in photoRequests += 1 }
        controller.setTabVisible(true)

        controller.configurationFailed()

        #expect(controller.state == .unavailable)
        #expect(log.runCalls.last == false)
        controller.takePhoto()
        controller.toggleRecording()
        #expect(photoRequests == 0, "a still was requested from a camera that is not there")
        #expect(log.recordingStarts == 0, "a clip was started on a camera that is not there")
    }

    /// Not sticky: a lid opened, or a camera released by another app, gets
    /// a fresh attempt the next time the tab is opened.
    @Test func reopeningTheTabRetriesAFailedConfigure() {
        let (controller, log) = makeController()
        controller.setTabVisible(true)
        controller.configurationFailed()

        controller.setTabVisible(false)
        controller.setTabVisible(true)

        #expect(controller.state == .previewing)
        #expect(log.runCalls.last == true)
    }

    /// A denied camera has no shutter either -- the buttons are disabled in
    /// the view, and the controller does not trust the view to have done it.
    @Test func aDeniedCameraTakesNothing() {
        let (controller, log) = makeController()
        var photoRequests = 0
        controller.capturePhoto = { _ in photoRequests += 1 }
        controller.authorizationStatus = { .denied }
        controller.setTabVisible(true)

        controller.takePhoto()
        controller.startRecording()

        #expect(photoRequests == 0)
        #expect(log.recordingStarts == 0)
    }

    // MARK: - The first-run prompt

    /// **Denying the first-run prompt must land on `.denied`.** Nothing
    /// re-read the grant after the user answered, so the tab sat on a black
    /// preview until it was closed and reopened.
    @Test func answeringThePromptReevaluatesTheGrant() async {
        let (controller, _) = makeController()
        var status: AVAuthorizationStatus = .notDetermined
        controller.authorizationStatus = { status }
        var answer: (@Sendable () -> Void)?
        var prompts = 0
        controller.requestAccess = { completion in
            prompts += 1
            answer = completion
        }
        controller.setTabVisible(true)
        #expect(prompts == 1)

        status = .denied
        answer?()
        for _ in 0..<50 where controller.state != .denied { await Task.yield() }

        #expect(controller.state == .denied)
    }

    /// One prompt, however many times the tab opens while it is up.
    @Test func thePromptIsRequestedOnce() {
        let (controller, _) = makeController()
        controller.authorizationStatus = { .notDetermined }
        var prompts = 0
        controller.requestAccess = { _ in prompts += 1 }

        controller.setTabVisible(true)
        controller.setTabVisible(false)
        controller.setTabVisible(true)

        #expect(prompts == 1)
    }

    // MARK: - Captures in flight

    final class WeakPhotoDelegate {
        weak var delegate: PhotoDelegate?
    }

    /// **`AVCapturePhotoOutput` holds its delegate weakly.** With one stored
    /// delegate, a second shutter press released the first one and its photo
    /// was never saved. The fake holds them weakly too, exactly as the real
    /// output does.
    @Test func aDoubleShutterSavesBothPhotos() async throws {
        let (controller, _) = makeController()
        controller.capturesDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Captures-\(UUID().uuidString)")
        var held: [WeakPhotoDelegate] = []
        controller.capturePhoto = { delegate in
            let box = WeakPhotoDelegate()
            box.delegate = delegate
            held.append(box)
        }
        controller.setTabVisible(true)

        controller.takePhoto(suffix: "aaaa")
        controller.takePhoto(suffix: "bbbb")
        #expect(held.count == 2)
        for box in held { box.delegate?.finish(Data("a photo".utf8)) }
        for _ in 0..<50 { await Task.yield() }

        let saved = try FileManager.default.contentsOfDirectory(atPath: controller.capturesDirectory.path)
        #expect(saved.count == 2, "a photo was lost to a released delegate")
    }

    /// **A late finish from the previous clip must not end the current one.**
    /// Stop, then record again quickly: the first clip's delegate reports
    /// after the second has started, and it used to clear `isRecording` for
    /// the take still running.
    @Test func aStaleFinishDoesNotEndTheCurrentRecording() {
        let (controller, _) = makeController()
        controller.capturesDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Captures-\(UUID().uuidString)")
        var urls: [URL] = []
        controller.beginRecording = { url, _ in urls.append(url) }
        controller.setTabVisible(true)

        controller.startRecording(suffix: "aaaa")
        controller.stopRecording()
        controller.startRecording(suffix: "bbbb")
        #expect(urls.count == 2)

        controller.didFinishRecording(urls[0])

        guard case .recording = controller.state else {
            Issue.record("the second take was ended by the first one's finish")
            return
        }
        #expect(controller.shouldBadge)
    }

    /// The current clip's own finish -- the size or duration ceiling -- does
    /// end it.
    @Test func theCurrentClipsFinishEndsIt() throws {
        let (controller, _) = makeController()
        controller.capturesDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Captures-\(UUID().uuidString)")
        var urls: [URL] = []
        controller.beginRecording = { url, _ in urls.append(url) }
        controller.setTabVisible(true)
        controller.startRecording()

        controller.didFinishRecording(try #require(urls.first))

        #expect(controller.state == .previewing)
        #expect(controller.shouldBadge == false)
    }

    // MARK: - Failed clips and collisions

    /// A clip that failed outright is not listed. One stopped at its ceiling
    /// reports an error too, but flags it as successfully finished.
    @Test func onlyUsableClipsCount() {
        #expect(MovieDelegate.isUsable(nil))
        let ceiling = NSError(
            domain: AVFoundationErrorDomain,
            code: AVError.maximumDurationReached.rawValue,
            userInfo: [AVErrorRecordingSuccessfullyFinishedKey: true]
        )
        #expect(MovieDelegate.isUsable(ceiling))
        let failed = NSError(domain: AVFoundationErrorDomain, code: AVError.diskFull.rawValue)
        #expect(!MovieDelegate.isUsable(failed))
        let explicitFailure = NSError(
            domain: AVFoundationErrorDomain,
            code: AVError.unknown.rawValue,
            userInfo: [AVErrorRecordingSuccessfullyFinishedKey: false]
        )
        #expect(!MovieDelegate.isUsable(explicitFailure))
    }

    @Test func aFailedClipIsNotAddedToTheShelf() throws {
        let shelf = try ShelfStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("CameraShelf-\(UUID().uuidString)"))
        let controller = CameraController(shelf: shelf)
        let clip = FileManager.default.temporaryDirectory
            .appendingPathComponent("Clip-\(UUID().uuidString).mov")
        try Data("half a clip".utf8).write(to: clip)

        controller.didFinishRecording(
            clip,
            error: NSError(domain: AVFoundationErrorDomain, code: AVError.diskFull.rawValue)
        )

        #expect(shelf.items.isEmpty, "a failed clip was listed")
    }

    /// **A photo never overwrites a file already there.** The random suffix
    /// makes it unlikely; it is not a guarantee, and the only copy of an
    /// earlier photo is not the thing to gamble.
    @Test func aPhotoNeverOverwritesAnExistingFile() throws {
        let controller = CameraController(shelf: nil)
        let existing = FileManager.default.temporaryDirectory
            .appendingPathComponent("Photo-\(UUID().uuidString).jpg")
        try Data("the earlier photo".utf8).write(to: existing)

        controller.didCapturePhoto(Data("a new photo".utf8), to: existing)

        #expect(try Data(contentsOf: existing) == Data("the earlier photo".utf8))
    }

    /// And a name that is already taken is replaced before the capture
    /// starts, rather than discovered afterwards.
    @Test func aTakenNameIsNotReused() throws {
        let (controller, _) = makeController()
        controller.capturesDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Captures-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: controller.capturesDirectory,
            withIntermediateDirectories: true
        )
        let now = Date()
        let taken = controller.capturesDirectory
            .appendingPathComponent(CaptureFileNaming.name(for: .clip, at: now, suffix: "abcd"))
        try Data("an earlier clip".utf8).write(to: taken)
        var urls: [URL] = []
        controller.beginRecording = { url, _ in urls.append(url) }
        controller.setTabVisible(true)

        controller.startRecording(now: now, suffix: "abcd")

        let url = try #require(urls.first)
        #expect(url != taken)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Quit

    /// **Quitting mid-recording finalizes the clip.** The session is torn
    /// down synchronously and the quit waits for the file to be closed --
    /// otherwise the process exits with the `.mov` missing its index.
    @Test func shuttingDownMidRecordingFinalizesTheClip() {
        let (controller, _) = makeController()
        controller.capturesDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Captures-\(UUID().uuidString)")
        var clip: (URL, MovieDelegate)?
        controller.beginRecording = { url, delegate in clip = (url, delegate) }
        var teardowns = 0
        controller.shutDownSession = {
            teardowns += 1
            if let (url, delegate) = clip { delegate.finish(url, error: nil) }
        }
        controller.setTabVisible(true)
        controller.startRecording()

        controller.shutDown()

        #expect(teardowns == 1)
        #expect(controller.shouldRun == false)
        #expect(controller.shouldBadge == false)
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
