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
    /// The camera's own queue, as `CameraSession` has one. Every attach and
    /// detach goes through it, so a test drains it before looking.
    private let queue = DispatchQueue(label: "test.camera")

    private func drained() { queue.sync {} }

    @Test func detachingReleasesTheSessionTheLayerWasHolding() {
        let view = PreviewLayerView(frame: .zero)
        let session = AVCaptureSession()

        view.attach(session: session, mirrored: true, on: queue)
        drained()
        #expect(view.isHoldingSession, "the layer never took the session, so releasing it proves nothing")

        view.detach(on: queue)
        drained()

        #expect(view.isHoldingSession == false)
    }

    /// **The crash of 2026-10-29.** Pointing the layer at the session is a
    /// change to the session -- AVFoundation adds a preview connection -- and
    /// it was made on the main thread while the camera queue was inside
    /// `startRunning()`, which enumerates the connections: "collection was
    /// mutated while being enumerated", and an abort. Granting access is what
    /// lined the two up, by restarting the session as the tab redrew.
    ///
    /// So the attach waits its turn on the camera queue. Held behind work
    /// already there -- a `startRunning()` -- it must not have happened yet.
    @Test func attachingWaitsForTheCameraQueue() {
        let view = PreviewLayerView(frame: .zero)
        let busy = DispatchSemaphore(value: 0)
        queue.async { busy.wait() }        // the queue, inside a start

        view.attach(session: AVCaptureSession(), mirrored: true, on: queue)
        #expect(view.isHoldingSession == false, "attached while the queue was busy: the race")

        busy.signal()
        drained()
        #expect(view.isHoldingSession)
    }

    /// Detaching is a change to the session too, and races a stop the same way.
    @Test func detachingWaitsForTheCameraQueue() {
        let view = PreviewLayerView(frame: .zero)
        view.attach(session: AVCaptureSession(), mirrored: true, on: queue)
        drained()
        let busy = DispatchSemaphore(value: 0)
        queue.async { busy.wait() }

        view.detach(on: queue)
        #expect(view.isHoldingSession, "detached while the queue was busy")

        busy.signal()
        drained()
        #expect(view.isHoldingSession == false)
    }

    /// Attaching the same session twice must not thrash the layer -- SwiftUI
    /// calls `updateNSView` on every body evaluation.
    @Test func attachingTheSameSessionTwiceIsHarmless() {
        let view = PreviewLayerView(frame: .zero)
        let session = AVCaptureSession()

        view.attach(session: session, mirrored: true, on: queue)
        view.attach(session: session, mirrored: true, on: queue)
        drained()

        #expect(view.isHoldingSession)
    }

    /// Detaching twice is a no-op, so a teardown path that runs twice does not
    /// have to ask first.
    @Test func detachingTwiceIsHarmless() {
        let view = PreviewLayerView(frame: .zero)
        view.attach(session: AVCaptureSession(), mirrored: true, on: queue)

        view.detach(on: queue)
        view.detach(on: queue)
        drained()

        #expect(view.isHoldingSession == false)
    }

    // MARK: - The denied state has a way out

    /// **A refusal must come with the way to undo it.** The denied message
    /// named the pane and offered nothing to click, in a panel that closes
    /// the moment the cursor leaves for System Settings. The deep link is the
    /// only part with a right answer; opening it is not seamed.
    @Test func theDeniedStateDeepLinksToTheCameraPane() throws {
        let url = try #require(CameraTabView.privacySettingsURL)
        #expect(url.scheme == "x-apple.systempreferences")
        #expect(url.absoluteString.hasSuffix("com.apple.preference.security?Privacy_Camera"))
    }
}
