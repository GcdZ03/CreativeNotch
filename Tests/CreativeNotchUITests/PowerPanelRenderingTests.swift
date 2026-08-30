import AppKit
import SwiftUI
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// That the *panel* draws what it was given.
///
/// `PowerLabelTests` proves the strings are right and `PowerWiringTests`
/// proves `AppState.power` is set. Neither proves the panel reads it:
/// `NotchRootView` could pass a constant and every other test in this
/// suite would stay green. That is the same gap that let the now-playing
/// peek ship undrawn.
@MainActor
struct PowerPanelRenderingTests {

    private static func panelPixels(
        level: Int = 54,
        source: PowerSource = .battery,
        isCharging: Bool = false,
        isCharged: Bool = false,
        isLowPowerMode: Bool = false
    ) -> Data? {
        let state = AppState()
        state.hasBattery = true
        state.power = PowerSnapshot(
            level: level, source: source, isCharging: isCharging,
            isCharged: isCharged, isLowPowerMode: isLowPowerMode
        )
        // Geometry matters: with the default zero `panelFrame` the panel
        // draws at zero size and clips its whole content away, so every
        // variant renders the same handful of bytes and the comparisons
        // below pass vacuously. An earlier draft of this file did exactly
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

    @Test func thePanelDrawsTheLevel() throws {
        #expect(try #require(Self.panelPixels(level: 54))
                != #require(Self.panelPixels(level: 91)))
    }

    /// The four states must be visually distinct, or the panel cannot tell
    /// the user that charging finished rather than never started.
    @Test func everyChargingStateDrawsDifferently() throws {
        let onBattery = try #require(Self.panelPixels(source: .battery))
        let charging = try #require(
            Self.panelPixels(source: .wall, isCharging: true))
        let notCharging = try #require(
            Self.panelPixels(source: .wall, isCharging: false))
        let charged = try #require(
            Self.panelPixels(source: .wall, isCharging: false, isCharged: true))

        #expect(Set([onBattery, charging, notCharging, charged]).count == 4)
    }

    @Test func lowPowerModeIsDrawn() throws {
        #expect(try #require(Self.panelPixels(isLowPowerMode: true))
                != #require(Self.panelPixels(isLowPowerMode: false)))
    }
}
