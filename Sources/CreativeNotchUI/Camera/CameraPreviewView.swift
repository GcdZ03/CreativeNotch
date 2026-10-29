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
    /// The camera's own queue (`CameraSession.queue`). Attaching and
    /// detaching are changes to the session, and happen there -- see
    /// `PreviewLayerView.attach(session:mirrored:on:)`.
    let queue: DispatchQueue
    /// The preview is mirrored; the saved file is not. Mirroring on the
    /// preview layer affects only what is drawn -- the capture connections
    /// carry their own, set to off in `CameraSession.configure()`.
    let isMirrored: Bool

    func makeNSView(context: Context) -> PreviewLayerView {
        let view = PreviewLayerView()
        view.attach(session: session, mirrored: isMirrored, on: queue)
        view.queue = queue
        return view
    }

    func updateNSView(_ view: PreviewLayerView, context: Context) {
        view.attach(session: session, mirrored: isMirrored, on: queue)
    }

    /// **This is the teardown that matters.**
    ///
    /// `AVCaptureVideoPreviewLayer.h` states it twice: *"The session is
    /// retained by the preview layer."* So removing this view does not release
    /// the session, and the graph would outlive the tab with nothing pointing
    /// at it. `stopRunning()` releases the *device* -- measured at 10ms -- but
    /// the retain cycle is a separate problem with a separate fix.
    static func dismantleNSView(_ view: PreviewLayerView, coordinator: ()) {
        if let queue = view.queue { view.detach(on: queue) }
    }
}

/// A layer-backed view that shows a capture session and declines every click.
final class PreviewLayerView: NSView {
    private let previewLayer = AVCaptureVideoPreviewLayer()

    /// The queue it attached on, so dismantling detaches on the same one.
    var queue: DispatchQueue?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        previewLayer.videoGravity = .resizeAspect
        layer = previewLayer
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Points the layer at `session`, **on the camera's queue**.
    ///
    /// Setting a preview layer's session is not a layer-only change: the
    /// session gains a preview connection, under its own configuration lock.
    /// Done here on the main thread, it raced `startRunning()` on the camera
    /// queue, which enumerates those connections -- and threw "collection was
    /// mutated while being enumerated", aborting the app (crash report
    /// 2026-10-29, v0.17.0, right after the camera was allowed). On the queue,
    /// it happens before or after a start or a stop, never during one, which
    /// is the rule `CameraSession` already keeps for every other change.
    ///
    /// Asynchronous, not `queue.sync`: a start can take hundreds of
    /// milliseconds, and the tab would freeze for it on every open. Wrapped in
    /// a transaction because a layer changed off the main thread has no run
    /// loop to commit it.
    func attach(session: AVCaptureSession, mirrored: Bool, on queue: DispatchQueue) {
        let layer = Unchecked(previewLayer)
        let session = Unchecked(session)
        queue.async {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            if layer.value.session !== session.value { layer.value.session = session.value }
            guard let connection = layer.value.connection,
                  connection.isVideoMirroringSupported else { return }
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirrored
        }
    }

    /// Releases the session the layer is holding, on the camera's queue for
    /// `attach`'s reason: removing the preview connection races a stop the
    /// same way. See `CameraPreview.dismantleNSView`.
    func detach(on queue: DispatchQueue) {
        let layer = Unchecked(previewLayer)
        queue.async {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.value.session = nil
            CATransaction.commit()
        }
    }

    /// Whether the layer is currently holding a session. Exposed for the same
    /// reason `PowerObserver.registrationCount` is: "we called detach" is not
    /// evidence that the retain went away.
    var isHoldingSession: Bool { previewLayer.session != nil }

    /// Declines every point, like `HoverTracker`. It draws; it never claims.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Carries a capture object onto the camera's queue. AVFoundation's types
/// have no `Sendable` annotations; what keeps this safe is the rule the box
/// exists for -- the value is only touched there.
private struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
