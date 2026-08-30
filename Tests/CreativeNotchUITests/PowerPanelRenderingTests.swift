import AppKit
import SwiftUI
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// That the *panel* draws the estimate it was given.
///
/// `PowerLabelTests` proves the string is right and `PowerWiringTests`
/// proves `AppState.powerEstimate` is set. Neither proves the panel reads
/// it: `NotchRootView` could pass `nil`, or `estimateMinutes:` could be
/// wired to the raw `snapshot.estimateMinutes` instead of the trusted one,
/// and every other test in this suite would stay green. That is the same
/// gap that let the now-playing peek ship undrawn.
@MainActor
struct PowerPanelRenderingTests {

    private static func panelPixels(estimate: Int?) -> Data? {
        let state = AppState()
        state.hasBattery = true
        state.power = PowerSnapshot(
            level: 54, source: .battery, isCharging: false,
            // Deliberately different from `estimate`: if the panel renders
            // this instead of the trusted value, the two cases below draw
            // identically and the test fails.
            estimateMinutes: 999, isLowPowerMode: false
        )
        state.powerEstimate = estimate
        // Geometry matters: with the default zero `panelFrame` the panel
        // draws at zero size and clips its whole content away, so every
        // variant renders the same handful of bytes and the comparison
        // below passes vacuously. The first draft of this test did exactly
        // that and "reproduced" a bug that was not there.
        state.setGeometry(
            anchor: .pill(CGRect(x: 100, y: 0, width: 200, height: 32)),
            panelFrame: CGRect(x: 0, y: 0, width: 420, height: 260)
        )
        state.transition(to: .open(.power))

        let renderer = ImageRenderer(
            content: NotchRootView(app: state).frame(width: 420, height: 260)
        )
        renderer.scale = 1
        guard
            let image = renderer.nsImage,
            let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff)
        else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    /// A trusted estimate must look different from a suppressed one.
    @Test func thePanelDrawsATrustedEstimate() throws {
        let shown = try #require(Self.panelPixels(estimate: 249))
        let estimating = try #require(Self.panelPixels(estimate: nil))

        #expect(shown != estimating)
    }

    /// And different estimates draw differently, so the panel is rendering
    /// the value rather than a constant.
    @Test func differentEstimatesDrawDifferently() throws {
        let a = try #require(Self.panelPixels(estimate: 249))
        let b = try #require(Self.panelPixels(estimate: 61))

        #expect(a != b)
    }
}

