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
    private let shelf: ShelfStore?
    private var recordingDelegate: MovieDelegate?

    private var isTabVisible = false
    private var isRecording = false
    private var isEnabled = true
    private var activity: SystemActivity = .active

    private(set) var state: State = .idle

    /// Published so the ear can show a recording that outlives the panel --
    /// which is what makes the activity-gate exemption honest.
    var onStateChange: ((State) -> Void)?

    /// Overridable so a test never triggers a real permission prompt.
    var authorizationStatus: () -> AVAuthorizationStatus = {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    /// Overridable so the tests never build a real capture graph. `swift test`
    /// has no Info.plist with a usage description, and Apple's documented
    /// response to that is termination.
    var applyRunState: (Bool) -> Void

    /// Starting and stopping the movie output, behind the same kind of seam
    /// and for the same reason: `AVCaptureMovieFileOutput` cannot be exercised
    /// in a test bundle, and the mid-recording disable path is exactly the one
    /// worth asserting.
    var beginRecording: (URL, MovieDelegate) -> Void
    var endRecording: () -> Void

    init(shelf: ShelfStore?) {
        self.shelf = shelf
        let session = self.session
        self.applyRunState = { shouldRun in
            session.queue.async {
                guard session.configure() else { return }
                shouldRun ? session.start() : session.stop()
            }
        }
        self.beginRecording = { url, delegate in
            session.queue.async { session.movieOutput.startRecording(to: url, recordingDelegate: delegate) }
        }
        self.endRecording = {
            session.queue.async { session.movieOutput.stopRecording() }
        }
    }

    var captureSession: AVCaptureSession { session.captureSession }

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
            default:
                break
            }
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

    // MARK: - Recording

    func startRecording(now: Date = Date(), suffix: String = UUID().uuidString.prefix(4).lowercased()) {
        guard !isRecording else { return }
        let name = CaptureFileNaming.name(for: .clip, at: now, suffix: suffix)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)

        isRecording = true
        reevaluate()

        let delegate = MovieDelegate { [weak self] finished in
            Task { @MainActor in self?.didFinishRecording(finished) }
        }
        recordingDelegate = delegate
        beginRecording(url, delegate)
    }

    func stopRecording() {
        guard isRecording else { return }
        endRecording()
        isRecording = false
        reevaluate()
    }

    private func didFinishRecording(_ url: URL) {
        recordingDelegate = nil
        // Landing on STOP rather than on start: `ShelfStore` has no notion of
        // a file still being written, so a clip added at the start would sit
        // in the shelf at zero bytes for the whole take.
        //
        // A failure is logged rather than swallowed. The shelf refuses a drop
        // it cannot store, and a clip that silently never arrives is the worst
        // outcome available -- the user watched the light stay on for it.
        do {
            try shelf?.add(.file(url), now: Date())
        } catch {
            NSLog("CreativeNotch: the shelf could not store a clip: \(error)")
        }
        isRecording = false
        reevaluate()
    }
}

/// The movie output's delegate. A separate object because
/// `AVCaptureFileOutputRecordingDelegate` is an Objective-C protocol and the
/// controller is `@MainActor`.
final class MovieDelegate: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    private let onFinish: (URL) -> Void

    init(onFinish: @escaping (URL) -> Void) {
        self.onFinish = onFinish
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        // A recording stopped at its size or duration ceiling reports an error
        // AND a usable file. Discarding it on any error would throw away a
        // clip that is exactly as long as the user was told it could be.
        onFinish(outputFileURL)
    }
}
