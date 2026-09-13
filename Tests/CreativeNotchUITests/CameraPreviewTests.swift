import AVFoundation
import AppKit
import Testing
@testable import CreativeNotchUI

/// The preview layer: the fourth thing that must decline a click, and the one
/// that holds the session alive.
///
/// No capture session is *started* here -- constructing an `AVCaptureSession`
/// object is safe without an Info.plist usage description; it is building an
/// input from a device that is not.
@MainActor
struct CameraPreviewTests {

    /// `ARCHITECTURE.md` records three layers that decline a click and the
    /// trap that each was individually correct while the assembly ate menu bar
    /// clicks across a 620pt band. A layer-backed view inside the panel is a
    /// fourth chance to make that mistake.
    @Test func thePreviewDeclinesEveryClick() {
        let view = PreviewLayerView(frame: NSRect(x: 0, y: 0, width: 400, height: 260))

        #expect(view.hitTest(NSPoint(x: 200, y: 130)) == nil, "the preview claimed a click")
        #expect(view.hitTest(NSPoint(x: 0, y: 0)) == nil)
        #expect(view.hitTest(NSPoint(x: 399, y: 259)) == nil)
    }

    /// **The preview layer retains the session** -- stated twice in Apple's
    /// header -- so removing the view is not enough. Without `detach()` the
    /// graph outlives the tab with nothing pointing at it.
    @Test func detachingReleasesTheSessionTheLayerWasHolding() {
        let view = PreviewLayerView(frame: .zero)
        let session = AVCaptureSession()

        view.attach(session: session, mirrored: true)
        #expect(view.isHoldingSession, "the layer never took the session, so releasing it proves nothing")

        view.detach()

        #expect(view.isHoldingSession == false)
    }

    /// Attaching the same session twice must not thrash the layer -- SwiftUI
    /// calls `updateNSView` on every body evaluation.
    @Test func attachingTheSameSessionTwiceIsHarmless() {
        let view = PreviewLayerView(frame: .zero)
        let session = AVCaptureSession()

        view.attach(session: session, mirrored: true)
        view.attach(session: session, mirrored: true)

        #expect(view.isHoldingSession)
    }

    /// Detaching twice is a no-op, so a teardown path that runs twice does not
    /// have to ask first.
    @Test func detachingTwiceIsHarmless() {
        let view = PreviewLayerView(frame: .zero)
        view.attach(session: AVCaptureSession(), mirrored: true)

        view.detach()
        view.detach()

        #expect(view.isHoldingSession == false)
    }
}
