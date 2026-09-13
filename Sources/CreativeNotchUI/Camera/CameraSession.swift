import AVFoundation
import AppKit
import CreativeNotchCore

/// The capture graph.
///
/// **Nothing here runs on the main actor**, and that is not a style choice.
/// `AVCaptureSession.startRunning()` and `stopRunning()` are both documented as
/// blocking — *"This call blocks until the session object has completely
/// started up or failed"* — so calling either from the main actor stalls the
/// UI for as long as the camera takes to come up, which on a cold start is
/// hundreds of milliseconds.
///
/// `@unchecked Sendable` because `AVCaptureSession` carries no `Sendable`
/// annotations at all — there is not one in `AVFoundation.apinotes` — and the
/// discipline this class actually keeps is that every mutation happens on
/// `queue`. That is asserted rather than assumed: `dispatchPrecondition` fires
/// in debug if it is ever false.
final class CameraSession: @unchecked Sendable {

    /// Its own serial queue. Named so it is identifiable in a sample.
    let queue = DispatchQueue(label: "com.gcdz.creativenotch.camera", qos: .userInitiated)

    private let session = AVCaptureSession()
    private var input: AVCaptureDeviceInput?
    private let photo = AVCapturePhotoOutput()
    private let movie = AVCaptureMovieFileOutput()

    private(set) var isConfigured = false

    /// The session, for the preview layer. **The layer retains it** — stated
    /// twice in `AVCaptureVideoPreviewLayer.h` — which is why the view must nil
    /// this when it goes away, and why `stopRunning()` alone does not release
    /// the graph even though it does release the device.
    var captureSession: AVCaptureSession { session }

    var photoOutput: AVCapturePhotoOutput { photo }
    var movieOutput: AVCaptureMovieFileOutput { movie }

    /// The built-in camera, and deliberately not `default(for:)` or
    /// `systemPreferredCamera`.
    ///
    /// Both of those can return a **Continuity Camera** — an iPhone on a desk
    /// across the room — which breaks this module's entire premise that the
    /// lens is above the preview. `isContinuityCamera` is the documented
    /// filter.
    static func builtInCamera() -> AVCaptureDevice? {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .unspecified
        )
        .devices
        .first { !$0.isContinuityCamera }
    }

    /// Builds the graph. Must run on `queue`.
    ///
    /// Returns `false` when there is no usable camera, rather than throwing:
    /// the caller's only sensible response is to show "no camera", and an
    /// error type with one case is ceremony.
    func configure() -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isConfigured else { return true }
        guard let device = Self.builtInCamera(),
              let deviceInput = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(deviceInput)
        else { return false }

        session.beginConfiguration()
        session.sessionPreset = .high
        session.addInput(deviceInput)
        input = deviceInput

        if session.canAddOutput(photo) { session.addOutput(photo) }
        if session.canAddOutput(movie) { session.addOutput(movie) }

        // The saved file is NOT mirrored, and the preview is -- mirroring is a
        // property of AVCaptureConnection and there is a separate connection
        // per output, so a `.scaleEffect(x: -1)` on the view would mirror the
        // preview and nothing else. Here the capture connections are left
        // unmirrored deliberately, so text in shot reads correctly in the file
        // and it matches what anyone else would see.
        for output in [photo as AVCaptureOutput, movie as AVCaptureOutput] {
            for connection in output.connections where connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
        }

        movie.maxRecordedDuration = CMTime(seconds: ClipLimits.maxDuration, preferredTimescale: 600)
        movie.maxRecordedFileSize = ClipLimits.maxBytes

        session.commitConfiguration()
        isConfigured = true
        return true
    }

    func start() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard isConfigured, !session.isRunning else { return }
        session.startRunning()
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard session.isRunning else { return }
        session.stopRunning()
    }

    var isRunning: Bool { session.isRunning }
}
