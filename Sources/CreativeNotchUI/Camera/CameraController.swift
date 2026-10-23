@preconcurrency import AVFoundation
import AppKit
import CreativeNotchCore

/// Owns the camera's lifecycle and decides, from `CameraRunReason`, whether
/// the session should be running.
///
/// The decision itself is pure and lives in Core; this is the part that acts
/// on it. Everything that could be argued about is over there, testable
/// without a camera.
@MainActor
final class CameraController {

    /// What the tab shows.
    enum State: Equatable, Sendable {
        case idle
        case denied
        case unavailable
        case previewing
        case recording(startedAt: Date)
    }

    private let session = CameraSession()

    /// The shelf, read at the moment a capture lands rather than stored.
    ///
    /// **A closure, not a `ShelfStore?`.** `AppDelegate` builds the camera
    /// before the shelf exists, and a stored copy of that `nil` meant every
    /// capture was saved and never listed. Reading it late also follows a
    /// shelf rebuilt afterwards, the same as the shelf's own title-row verbs.
    private let currentShelf: @MainActor () -> ShelfStore?

    /// Where captures are kept.
    ///
    /// **`~/Pictures/CreativeNotch/`, not the shelf's own storage.** The shelf
    /// is a staging area with retention rules -- seven days, twenty items,
    /// both enforced by moving files to the Trash -- which is right for a file
    /// dragged in from somewhere it still exists, and wrong for the only copy
    /// of a photograph the user just took.
    ///
    /// The shelf still shows them, as references it does not own, so they are
    /// as draggable as anything else and nothing auto-deletes them.
    var capturesDirectory: URL = FileManager.default
        .urls(for: .picturesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("CreativeNotch")
    /// Every capture still waiting on its delegate, keyed by its destination.
    ///
    /// **Plural, because both outputs hold their delegates weakly**, so this
    /// is the only strong reference. A single slot meant a second shutter
    /// press released the first photo's delegate, and a record pressed
    /// straight after a stop released the previous clip's -- each one a
    /// capture that silently never arrived. Destinations are unique by
    /// construction (see `prepareCaptureURL`), which makes them a usable key.
    private var inFlightPhotos: [URL: PhotoDelegate] = [:]
    private var inFlightClips: [URL: MovieDelegate] = [:]

    /// The clip being recorded right now, so a late finish from an earlier
    /// take can be told apart from the current one ending.
    private var recordingURL: URL?

    private var isTabVisible = false
    private var isRecording = false
    private var isEnabled = true
    private var activity: SystemActivity = .active

    /// `CameraSession.configure()` failed: no built-in camera, the lid shut
    /// on a laptop, or another process holding it. Cleared whenever the
    /// session is not wanted, so the next opening of the tab tries again.
    private var isUnavailable = false

    /// A first-run prompt is on screen, so a second is not requested.
    private var isAwaitingPrompt = false

    private(set) var state: State = .idle

    /// Published so the ear can show a recording that outlives the panel --
    /// which is what makes the activity-gate exemption honest.
    var onStateChange: ((State) -> Void)?

    /// Overridable so a test never triggers a real permission prompt.
    var authorizationStatus: () -> AVAuthorizationStatus = {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    /// Asks the user for the camera, calling back once they have answered.
    ///
    /// Overridable for the same reason as `authorizationStatus`. **The answer
    /// is what matters, not the grant**: before this, nothing re-read the
    /// status after the first-run prompt, so declining it left the tab on a
    /// black preview until it was closed and reopened.
    var requestAccess: (@escaping @Sendable () -> Void) -> Void = { completion in
        guard CameraController.mayUseCamera(Bundle.main.infoDictionary) else { return }
        AVCaptureDevice.requestAccess(for: .video) { _ in completion() }
    }

    /// Overridable so the tests never build a real capture graph. `swift test`
    /// has no Info.plist with a usage description, and Apple's documented
    /// response to that is termination.
    var applyRunState: (Bool) -> Void = { _ in }

    /// Starting and stopping the movie output, behind the same kind of seam
    /// and for the same reason: `AVCaptureMovieFileOutput` cannot be exercised
    /// in a test bundle, and the mid-recording disable path is exactly the one
    /// worth asserting.
    var beginRecording: (URL, MovieDelegate) -> Void
    var endRecording: () -> Void

    /// Taking a still, behind a seam for the same reason: `AVCapturePhotoOutput`
    /// cannot be exercised in a test bundle.
    var capturePhoto: (PhotoDelegate) -> Void

    /// Tearing the session down at quit, **synchronously**: stopping any
    /// recording and the session before `applicationWillTerminate` returns.
    /// Behind a seam because it blocks on the camera queue.
    var shutDownSession: () -> Void

    /// How long quit waits for a clip to be closed. Bounded, because the
    /// delegate's queue is AVFoundation's to choose and a quit that can hang
    /// is worse than a clip that is cut short.
    static let finalizeTimeout: TimeInterval = 5

    /// What a capture sent to an unconfigured session finishes with. Carries
    /// no `AVErrorRecordingSuccessfullyFinishedKey`, so it is never listed.
    nonisolated static let notConfiguredError = NSError(
        domain: AVFoundationErrorDomain,
        code: AVError.deviceNotConnected.rawValue
    )

    init(shelf: @escaping @MainActor () -> ShelfStore?) {
        self.currentShelf = shelf
        let session = self.session
        // Every capture checks for a video connection ON the queue, after any
        // pending `configure()`: an output with none -- no camera, or one the
        // session declined to add -- answers `capturePhoto` and
        // `startRecording` with an Objective-C exception, and the state the
        // button was enabled by can be a hop behind the queue.
        self.beginRecording = { url, delegate in
            session.queue.async {
                guard session.movieOutput.connection(with: .video) != nil else {
                    delegate.finish(url, error: CameraController.notConfiguredError)
                    return
                }
                session.movieOutput.startRecording(to: url, recordingDelegate: delegate)
            }
        }
        self.endRecording = {
            session.queue.async { session.movieOutput.stopRecording() }
        }
        self.capturePhoto = { delegate in
            session.queue.async {
                guard session.photoOutput.connection(with: .video) != nil else {
                    delegate.finish(nil)
                    return
                }
                session.photoOutput.capturePhoto(with: AVCapturePhotoSettings(), delegate: delegate)
            }
        }
        self.shutDownSession = {
            guard CameraController.mayUseCamera(Bundle.main.infoDictionary) else { return }
            session.queue.sync {
                if session.movieOutput.isRecording { session.movieOutput.stopRecording() }
                session.stop()
            }
        }
        // Assigned last, because it reports a failed configure back to `self`.
        self.applyRunState = { [weak self] shouldRun in
            // No usage description, no camera: that is `swift test`, and
            // macOS terminates a process that starts the camera without one
            // (2026-10-17). The packaged app's Info.plist has it.
            guard CameraController.mayUseCamera(Bundle.main.infoDictionary) else { return }
            session.queue.async { [weak self] in
                guard shouldRun else {
                    session.stop()
                    return
                }
                guard session.configure() else {
                    Task { @MainActor [weak self] in self?.configurationFailed() }
                    return
                }
                session.start()
            }
        }
    }

    /// A shelf that is fixed for the controller's lifetime, which is what
    /// the tests want.
    convenience init(shelf: ShelfStore?) {
        self.init(shelf: { shelf })
    }

    var captureSession: AVCaptureSession { session.captureSession }

    /// The camera's own queue, so a test can wait for work sent to it.
    var sessionQueue: DispatchQueue { session.queue }

    /// Whether this process may touch the camera at all: only one that
    /// declares why, in `NSCameraUsageDescription`.
    nonisolated static func mayUseCamera(_ info: [String: Any]?) -> Bool {
        guard let text = info?["NSCameraUsageDescription"] as? String else { return false }
        return !text.isEmpty
    }

    // MARK: - Inputs

    func setTabVisible(_ visible: Bool) {
        isTabVisible = visible
        reevaluate()
    }

    func setActivity(_ next: SystemActivity) {
        activity = next
        reevaluate()
    }

    /// Only ever called by `ModuleSwitchboard`. **Switching off stops the
    /// session even mid-recording** -- the switch is a stronger statement than
    /// the cursor moving -- and the partial clip is saved rather than
    /// discarded.
    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if !enabled, isRecording { stopRecording() }
        reevaluate()
    }

    private var inputs: CameraRunReason.Inputs {
        .init(
            isTabVisible: isTabVisible,
            isRecording: isRecording,
            isEnabled: isEnabled,
            activity: activity
        )
    }

    /// Whether the session should be running, by the rule in Core.
    var shouldRun: Bool { CameraRunReason.shouldRun(inputs) }
    var shouldPreview: Bool { CameraRunReason.shouldPreview(inputs) }
    /// Whether the ear shows a recording. The honesty half of the exemption.
    var shouldBadge: Bool { CameraRunReason.shouldBadge(inputs) }

    private func reevaluate() {
        // Read the grant BEFORE building the graph. A denied camera vends
        // black frames rather than an error, so without this it is
        // indistinguishable from a bug.
        if shouldRun {
            switch authorizationStatus() {
            case .denied, .restricted:
                setState(.denied)
                applyRunState(false)
                return
            case .notDetermined:
                // The graph is still built below -- that is what puts the
                // prompt up -- but the answer must come back here, or a
                // refusal reads as a black preview.
                requestAccessOnce()
            default:
                break
            }

            // Not attempted again while the tab stays open: a configure that
            // later succeeded would leave a running camera behind a "No
            // camera" message.
            if isUnavailable {
                setState(.unavailable)
                applyRunState(false)
                return
            }
        } else {
            isUnavailable = false
        }

        applyRunState(shouldRun)

        if isRecording {
            if case .recording = state {} else { setState(.recording(startedAt: Date())) }
        } else if shouldPreview {
            setState(.previewing)
        } else {
            setState(.idle)
        }
    }

    private func setState(_ next: State) {
        guard next != state else { return }
        state = next
        onStateChange?(next)
    }

    /// Called back from the camera queue when `CameraSession.configure()`
    /// returns `false`. Internal so a test can drive it without hardware.
    func configurationFailed() {
        isUnavailable = true
        reevaluate()
    }

    private func requestAccessOnce() {
        guard !isAwaitingPrompt else { return }
        isAwaitingPrompt = true
        requestAccess { [weak self] in
            Task { @MainActor [weak self] in
                self?.isAwaitingPrompt = false
                self?.reevaluate()
            }
        }
    }

    /// Whether there is a working camera behind the buttons. The view
    /// disables them in the other states too; this does not rely on it.
    private var canCapture: Bool {
        switch state {
        case .previewing, .recording: return true
        case .idle, .denied, .unavailable: return false
        }
    }

    // MARK: - Recording

    func startRecording(now: Date = Date(), suffix: String = CameraController.randomSuffix()) {
        guard !isRecording, canCapture else { return }
        // Recorded straight to its final home. Writing to a temporary
        // directory and copying afterwards means a 512 MB clip exists twice
        // and the temporary one is never cleaned up -- which is exactly what
        // the first version of this did.
        guard let url = prepareCaptureURL(for: .clip, at: now, suffix: suffix) else { return }

        isRecording = true
        recordingURL = url
        reevaluate()

        let delegate = MovieDelegate { [weak self] finished, error in
            Task { @MainActor in self?.didFinishRecording(finished, error: error) }
        }
        inFlightClips[url] = delegate
        beginRecording(url, delegate)
    }

    /// Toggles recording, which is what the single record button does.
    func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    /// Captures a still.
    ///
    /// The saved file is **not** mirrored even though the preview is --
    /// mirroring lives on the capture connection, set to off in
    /// `CameraSession.configure()`, so text in shot reads correctly.
    func takePhoto(now: Date = Date(), suffix: String = CameraController.randomSuffix()) {
        guard shouldRun, canCapture else { return }
        guard let url = prepareCaptureURL(for: .still, at: now, suffix: suffix) else { return }

        let delegate = PhotoDelegate { [weak self] data in
            Task { @MainActor in self?.didCapturePhoto(data, to: url) }
        }
        inFlightPhotos[url] = delegate
        capturePhoto(delegate)
    }

    /// Internal so a test can drive the shelf path without a capture graph.
    func didCapturePhoto(_ data: Data?, to url: URL) {
        inFlightPhotos[url] = nil
        guard let data else { return }
        do {
            // `.withoutOverwriting`: the name was checked free when the
            // shutter was pressed, and if anything has taken it since, the
            // earlier file is somebody's only copy.
            try data.write(to: url, options: .withoutOverwriting)
            try currentShelf()?.addReference(to: url, now: Date())
        } catch {
            NSLog("CreativeNotch: could not save a photo: \(error)")
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        endRecording()
        isRecording = false
        recordingURL = nil
        reevaluate()
    }

    /// Stops everything before the process exits, and waits for a clip in
    /// progress to be closed.
    ///
    /// **A `.mov` is not playable until its index is written**, which happens
    /// after `stopRecording()` returns. Quitting mid-take without waiting
    /// exits first and leaves a file of the right size that nothing opens.
    /// The clip is not listed on the shelf -- the main actor is blocked here,
    /// and the app is going away -- but it is in the captures folder, intact.
    func shutDown() {
        let clip = recordingURL.flatMap { inFlightClips[$0] }
        isEnabled = false
        isRecording = false
        recordingURL = nil
        shutDownSession()
        if let clip {
            _ = clip.finished.wait(timeout: .now() + Self.finalizeTimeout)
        }
        reevaluate()
    }

    nonisolated static func randomSuffix() -> String {
        String(UUID().uuidString.prefix(4)).lowercased()
    }

    /// The destination for a capture, with its directory created and a name
    /// nothing already has.
    ///
    /// Returns `nil` when the directory cannot be made -- a sandbox denial, a
    /// full disk -- rather than letting the capture start and fail later:
    /// `AVCaptureFileOutput` reports a bad destination asynchronously, long
    /// after the button was pressed, which reads as the clip vanishing.
    ///
    /// **The existence check is what makes the suffix a guarantee.** Four hex
    /// characters inside one second collide rarely, not never, and a movie
    /// output refuses an existing file asynchronously, the same way.
    private func prepareCaptureURL(
        for kind: CaptureFileNaming.Kind,
        at now: Date,
        suffix: String
    ) -> URL? {
        do {
            try FileManager.default.createDirectory(
                at: capturesDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            NSLog("CreativeNotch: could not create the captures directory: \(error)")
            return nil
        }
        var url = capturesDirectory
            .appendingPathComponent(CaptureFileNaming.name(for: kind, at: now, suffix: suffix))
        while FileManager.default.fileExists(atPath: url.path) || inFlightPhotos[url] != nil {
            url = capturesDirectory.appendingPathComponent(
                CaptureFileNaming.name(for: kind, at: now, suffix: Self.randomSuffix())
            )
        }
        return url
    }

    /// Internal so a test can drive the shelf path without a capture graph.
    func didFinishRecording(_ url: URL, error: Error? = nil) {
        inFlightClips[url] = nil
        // Landing on STOP rather than on start: `ShelfStore` has no notion of
        // a file still being written, so a clip added at the start would sit
        // in the shelf at zero bytes for the whole take.
        //
        // A failure is logged rather than swallowed. The shelf refuses a drop
        // it cannot store, and a clip that silently never arrives is the worst
        // outcome available -- the user watched the light stay on for it.
        // A reference, not a copy: the file is already where it belongs, and
        // the shelf must never trash it.
        if MovieDelegate.isUsable(error) {
            do {
                try currentShelf()?.addReference(to: url, now: Date())
            } catch {
                NSLog("CreativeNotch: the shelf could not list a clip: \(error)")
            }
        } else {
            NSLog("CreativeNotch: a clip failed to record: \(String(describing: error))")
        }

        // A finish for an earlier take -- stop, then record again before the
        // first file closed -- lists that clip and leaves the current one
        // alone. Clearing `isRecording` here would end a take still running.
        guard url == recordingURL else { return }
        recordingURL = nil
        isRecording = false
        reevaluate()
    }
}

/// The photo output's delegate, for the same reason as the movie one.
final class PhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let onCapture: (Data?) -> Void

    init(onCapture: @escaping (Data?) -> Void) {
        self.onCapture = onCapture
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        finish(photo.fileDataRepresentation())
    }

    /// Also how a capture refused before reaching the output reports, so its
    /// entry in the controller's in-flight table is released either way.
    func finish(_ data: Data?) {
        onCapture(data)
    }
}

/// The movie output's delegate. A separate object because
/// `AVCaptureFileOutputRecordingDelegate` is an Objective-C protocol and the
/// controller is `@MainActor`.
final class MovieDelegate: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    private let onFinish: (URL, Error?) -> Void

    /// Signalled once the file is closed, so quit can wait for it without
    /// the main actor, which quit is blocking.
    let finished = DispatchSemaphore(value: 0)

    init(onFinish: @escaping (URL, Error?) -> Void) {
        self.onFinish = onFinish
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        finish(outputFileURL, error: error)
    }

    /// Also how a recording refused before reaching the output reports.
    func finish(_ url: URL, error: Error?) {
        onFinish(url, error)
        finished.signal()
    }

    /// Whether a finished recording left a clip worth keeping.
    ///
    /// **Not simply `error == nil`.** A recording stopped at its size or
    /// duration ceiling reports an error AND a usable file, flagged by
    /// `AVErrorRecordingSuccessfullyFinishedKey`; discarding it would throw
    /// away a clip exactly as long as the user was told it could be. Any
    /// other error -- a full disk, a lost device -- left nothing playable.
    nonisolated static func isUsable(_ error: Error?) -> Bool {
        guard let error else { return true }
        let flag = (error as NSError).userInfo[AVErrorRecordingSuccessfullyFinishedKey]
        return (flag as? Bool) ?? false
    }
}
