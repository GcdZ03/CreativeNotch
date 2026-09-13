@preconcurrency import AVFoundation
import AppKit
import SwiftUI

/// The live preview.
///
/// **The fourth layer that must decline a click.** `ARCHITECTURE.md` names
/// three -- `PassthroughContainer`, `HoverTracker`, `HitTestingHostingView` --
/// and the trap it records is that each was individually correct while the
/// assembly ate menu bar clicks across a 620pt band. A layer-backed `NSView`
/// added inside the panel is a fourth chance to make that mistake, so this one
/// declines too: it draws, and it never claims a point.
///
/// The shutter and record buttons are SwiftUI siblings rather than subviews of
/// this, precisely so the clicks they need are not routed through a view whose
/// whole job is to decline them.
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    /// The preview is mirrored; the saved file is not. Mirroring on the
    /// preview layer affects only what is drawn -- the capture connections
    /// carry their own, set to off in `CameraSession.configure()`.
    let isMirrored: Bool

    func makeNSView(context: Context) -> PreviewLayerView {
        let view = PreviewLayerView()
        view.attach(session: session, mirrored: isMirrored)
        return view
    }

    func updateNSView(_ view: PreviewLayerView, context: Context) {
        view.attach(session: session, mirrored: isMirrored)
    }

    /// **This is the teardown that matters.**
    ///
    /// `AVCaptureVideoPreviewLayer.h` states it twice: *"The session is
    /// retained by the preview layer."* So removing this view does not release
    /// the session, and the graph would outlive the tab with nothing pointing
    /// at it. `stopRunning()` releases the *device* -- measured at 10ms -- but
    /// the retain cycle is a separate problem with a separate fix.
    static func dismantleNSView(_ view: PreviewLayerView, coordinator: ()) {
        view.detach()
    }
}

/// A layer-backed view that shows a capture session and declines every click.
final class PreviewLayerView: NSView {
    private let previewLayer = AVCaptureVideoPreviewLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        previewLayer.videoGravity = .resizeAspect
        layer = previewLayer
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func attach(session: AVCaptureSession, mirrored: Bool) {
        if previewLayer.session !== session { previewLayer.session = session }
        guard let connection = previewLayer.connection,
              connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = mirrored
    }

    /// Releases the session the layer is holding. See
    /// `CameraPreview.dismantleNSView`.
    func detach() {
        previewLayer.session = nil
    }

    /// Whether the layer is currently holding a session. Exposed for the same
    /// reason `PowerObserver.registrationCount` is: "we called detach" is not
    /// evidence that the retain went away.
    var isHoldingSession: Bool { previewLayer.session != nil }

    /// Declines every point, like `HoverTracker`. It draws; it never claims.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
