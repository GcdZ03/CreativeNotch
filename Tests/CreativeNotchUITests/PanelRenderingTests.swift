import AppKit
import SwiftUI
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// That the recomposed panel draws where the spec says (spec §5).
///
/// Pixel tests, in the shape `PowerPanelRenderingTests` established: build
/// an `AppState`, give it real geometry, render `NotchRootView` offscreen,
/// and ask where the ink is. `ImageRenderer` does not run `ScrollView`
/// content, so list *contents* are asserted through their pure functions;
/// what is asserted here is the frame around them.
@MainActor
struct PanelRenderingTests {

    /// 14" MacBook Pro-ish: a 190×32 notch, a 620×260 panel centred on it.
    /// In the rendered image the notch band is x 215..405, y 0..32.
    static func state(notch: Bool = true, media: Bool = true) -> AppState {
        let s = AppState()
        let anchor: CreativeNotchCore.Anchor = notch
            ? .notch(CGRect(x: 661, y: 950, width: 190, height: 32))
            : .pill(CGRect(x: 666, y: 942, width: 180, height: 32))
        s.setGeometry(
            anchor: anchor,
            panelFrame: CGRect(x: 446, y: anchor.rect.maxY - 260, width: 620, height: 260)
        )
        s.hasBattery = true
        s.showsMediaControls = media
        s.power = PowerSnapshot(level: 67, source: .battery, isCharging: false, isLowPowerMode: false)
        return s
    }

    static func bitmap(_ s: AppState) -> NSBitmapImageRep? {
        let renderer = ImageRenderer(
            content: NotchRootView(app: s, now: Date(timeIntervalSinceReferenceDate: 0))
                .frame(width: 620, height: 260)
        )
        renderer.scale = 1
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)
    }

    /// Fraction of pixels in `rect` (top-left origin, points) that are not
    /// black. Transparent pixels count as black, which is what they are on
    /// top of the black shape.
    static func ink(_ b: NSBitmapImageRep, in rect: CGRect) -> Double {
        var lit = 0, total = 0
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                guard let c = b.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                total += 1
                if c.alphaComponent > 0.05,
                   c.redComponent + c.greenComponent + c.blueComponent > 0.15 {
                    lit += 1
                }
            }
        }
        return total == 0 ? 0 : Double(lit) / Double(total)
    }

    /// The header draws in the ears and leaves the camera housing black.
    /// The old layout centred the tab bar straight under the notch.
    @Test func theHeaderStaysOutOfTheNotch() throws {
        let s = Self.state()
        s.transition(to: .open(.shelf))
        let b = try #require(Self.bitmap(s))

        #expect(Self.ink(b, in: CGRect(x: 220, y: 2, width: 180, height: 28)) == 0,
                "something was drawn behind the camera housing")
        #expect(Self.ink(b, in: CGRect(x: 0, y: 2, width: 215, height: 28)) > 0.01,
                "no tabs in the leading ear")
        #expect(Self.ink(b, in: CGRect(x: 405, y: 2, width: 215, height: 28)) > 0.01,
                "no gear in the trailing ear")
    }

    /// The media column is a fixed left column when controls are on, and
    /// absent when they are off. The cover tile's own rectangle is what is
    /// checked: lit by the placeholder tile with the column, black without.
    @Test func theMediaColumnIsDrawnOnTheLeftWhenControlsAreOn() throws {
        let with = Self.state(media: true)
        with.transition(to: .open(.timer))
        let without = Self.state(media: false)
        without.transition(to: .open(.timer))
        let a = try #require(Self.bitmap(with))
        let c = try #require(Self.bitmap(without))

        let cover = CGRect(x: 22, y: 60, width: 60, height: 56)
        #expect(Self.ink(a, in: cover) > 0.5, "no cover tile where the column should be")
        #expect(Self.ink(c, in: cover) < 0.05, "something drawn where the absent column would be")
    }

    /// The camera takes the whole body: no column beside the preview.
    @Test func theCameraTabHasNoMediaColumn() throws {
        let s = Self.state(media: true)
        s.transition(to: .open(.camera))
        let b = try #require(Self.bitmap(s))
        #expect(Self.ink(b, in: CGRect(x: 22, y: 60, width: 60, height: 56)) < 0.05)
    }

    /// On a pill there is no housing to avoid; the tabs start at the left.
    @Test func aPillDrawsTheHeaderAcrossTheMiddle() throws {
        let s = Self.state(notch: false)
        s.transition(to: .open(.shelf))
        let b = try #require(Self.bitmap(s))
        #expect(Self.ink(b, in: CGRect(x: 4, y: 2, width: 60, height: 28)) > 0.01)
    }

    /// A dashed border lights the top edge of the content area; the old
    /// bare centred label left it black.
    @Test func receivingDrawsATargetNotJustALabel() throws {
        let s = Self.state()
        s.transition(to: .receiving)
        let b = try #require(Self.bitmap(s))
        #expect(Self.ink(b, in: CGRect(x: 30, y: 41, width: 560, height: 5)) > 0.05)
    }

    /// The edge (spec §4): a hairline on the expanded shape, none on the
    /// closed notch, which must vanish into the housing.
    @Test func theHairlineIsOnTheOpenPanelOnly() throws {
        let open = Self.state()
        open.transition(to: .open(.shelf))
        let closed = Self.state()
        let a = try #require(Self.bitmap(open))
        let c = try #require(Self.bitmap(closed))
        // The panel's left edge, well below the header.
        #expect(Self.ink(a, in: CGRect(x: 0, y: 100, width: 1, height: 100)) > 0.5)
        // The closed notch occupies x 215..405, y 0..32; its left edge is black.
        #expect(Self.ink(c, in: CGRect(x: 215, y: 4, width: 1, height: 20)) == 0)
    }

    @Test func theShelfCountReadsAsEnglish() {
        #expect(NotchRootView.shelfCount(0) == "empty")
        #expect(NotchRootView.shelfCount(1) == "1 item")
        #expect(NotchRootView.shelfCount(4) == "4 items")
    }
}
