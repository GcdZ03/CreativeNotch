import AppKit
import SwiftUI
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// The colour picker in the open panel (2026-10-24): the dropper in the
/// trailing ear, and the result strip over the body.
///
/// Pixel tests in `PanelRenderingTests`' shape, on its 14" geometry: the
/// trailing ear is x 405..620 and the camera housing x 215..405, y 0..32.
///
/// `exportFeatureRenders` also writes the PNGs under
/// `docs/assets/features/`, but only when `CREATIVENOTCH_RENDER_FEATURES` is
/// set, so the normal suite never rewrites files:
///
///     CREATIVENOTCH_RENDER_FEATURES=1 swift test --filter ColorPickerRenderingTests
@MainActor
struct ColorPickerRenderingTests {

    static let picks: [SampledColor] = [
        SampledColor(red8: 58, green8: 123, blue8: 213),    // #3A7BD5
        SampledColor(red8: 255, green8: 94, blue8: 58),     // #FF5E3A
        SampledColor(red8: 52, green8: 199, blue8: 89),     // #34C759
        SampledColor(red8: 255, green8: 204, blue8: 0),     // #FFCC00
        SampledColor(red8: 175, green8: 82, blue8: 222),    // #AF52DE
    ]

    /// An open panel holding a pick, with `history` in the strip.
    static func picked(
        _ s: AppState, history: [SampledColor] = picks, format: ColorFormat = .hex
    ) -> AppState {
        s.recentColors = history
        s.colorFormat = format
        s.transition(to: .open(.timer))
        s.pickedColor = history.first
        return s
    }

    // MARK: - The dropper

    /// On, the dropper draws in the trailing ear, between the housing and the
    /// battery; off, that stretch of the ear is black.
    @Test func theDropperDrawsInTheTrailingEarOnlyWhileOn() throws {
        let on = PanelRenderingTests.state()
        on.transition(to: .open(.timer))
        let off = PanelRenderingTests.state()
        off.preferences.colorPicker = false
        off.transition(to: .open(.timer))

        let a = try #require(PanelRenderingTests.bitmap(on))
        let c = try #require(PanelRenderingTests.bitmap(off))
        let stretch = CGRect(x: 410, y: 4, width: 80, height: 24)
        #expect(PanelRenderingTests.ink(a, in: stretch) > 0.01, "no dropper beside the battery")
        #expect(PanelRenderingTests.ink(c, in: stretch) == 0, "a switched-off picker still drew")
        // And never behind the camera housing.
        #expect(PanelRenderingTests.ink(a, in: CGRect(x: 220, y: 2, width: 180, height: 28)) == 0)
    }

    /// The header is handed the dropper only while the module is on, with
    /// the history and the format it should offer.
    @Test func theHeaderModelFollowsTheSwitch() throws {
        let s = AppState()
        s.recentColors = Self.picks
        s.colorFormat = .hsl
        let model = try #require(NotchRootView.colorPickerHeader(for: s))
        #expect(model.recent == Self.picks)
        #expect(model.format == .hsl)

        s.preferences.colorPicker = false
        #expect(NotchRootView.colorPickerHeader(for: s) == nil)
    }

    /// At every text size the dropper fits the ear: the housing stays black.
    @Test(arguments: TextSize.allCases)
    func theDropperStaysOutOfTheHousing(size: TextSize) throws {
        let s = TextSizeRenderingTests.state(size)
        s.transition(to: .open(.timer))
        let b = try #require(TextSizeRenderingTests.bitmap(s))
        #expect(PanelRenderingTests.ink(b, in: TextSizeRenderingTests.housing(s)) == 0)
    }

    // MARK: - The strip

    /// The strip draws the picked colour itself, near the bottom-left of the
    /// body, and nothing there without a pick.
    @Test func theStripShowsThePickedColour() throws {
        let with = Self.picked(PanelRenderingTests.state())
        let without = PanelRenderingTests.state()
        without.transition(to: .open(.timer))
        let a = try #require(PanelRenderingTests.bitmap(with))
        let c = try #require(PanelRenderingTests.bitmap(without))

        let blue = try #require(Self.firstPixel(in: a, matching: Self.picks[0], within: CGRect(x: 12, y: 190, width: 80, height: 60)))
        #expect(blue.y > 190)
        #expect(Self.firstPixel(in: c, matching: Self.picks[0], within: CGRect(x: 12, y: 190, width: 80, height: 60)) == nil)
    }

    /// Every recent colour gets a swatch.
    @Test func everyRecentColourHasASwatch() throws {
        let b = try #require(PanelRenderingTests.bitmap(Self.picked(PanelRenderingTests.state())))
        let strip = CGRect(x: 12, y: 190, width: 596, height: 60)
        for color in Self.picks {
            #expect(Self.firstPixel(in: b, matching: color, within: CGRect(x: 300, y: strip.minY, width: 300, height: strip.height)) != nil,
                    "no swatch for \(ColorFormat.hex.string(for: color))")
        }
    }

    /// The strip keeps clear of the strip every pane keeps clear at the
    /// bottom, at every text size and in the longest format.
    @Test(arguments: TextSize.allCases)
    func theStripDoesNotRunOffTheBottom(size: TextSize) throws {
        let s = Self.picked(TextSizeRenderingTests.state(size), format: .swiftUI)
        let b = try #require(TextSizeRenderingTests.bitmap(s))
        #expect(TextSizeRenderingTests.stripInk(b, s) == 0)
    }

    /// The first pick has no history to show: the strip draws no second
    /// swatch of the colour already beside the value.
    @Test func aFirstPickShowsNoRecentRow() throws {
        let b = try #require(PanelRenderingTests.bitmap(
            Self.picked(PanelRenderingTests.state(), history: [Self.picks[0]])
        ))
        #expect(Self.firstPixel(in: b, matching: Self.picks[0], within: CGRect(x: 300, y: 210, width: 260, height: 40)) == nil)
        #expect(Self.firstPixel(in: b, matching: Self.picks[0], within: CGRect(x: 12, y: 210, width: 60, height: 40)) != nil)
    }

    @Test func theMenuSwatchKeepsItsColour() {
        let image = ColorSwatchImage.menu(for: Self.picks[0])
        #expect(image.isTemplate == false)
        #expect(image.size == NSSize(width: 12, height: 12))
    }

    /// Where `color` first appears in `rect` (top-left origin), within a
    /// small tolerance for anti-aliasing.
    ///
    /// The bitmap's own components, unconverted: the renderer writes sRGB
    /// values, but `colorAt` tags them as calibrated RGB, and converting that
    /// "to sRGB" shifts every channel by several steps.
    static func firstPixel(in b: NSBitmapImageRep, matching color: SampledColor, within rect: CGRect) -> CGPoint? {
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                guard let c = b.colorAt(x: x, y: y), c.colorSpace.colorSpaceModel == .rgb else { continue }
                if abs(c.redComponent - color.red) < 0.04,
                   abs(c.greenComponent - color.green) < 0.04,
                   abs(c.blueComponent - color.blue) < 0.04 {
                    return CGPoint(x: x, y: y)
                }
            }
        }
        return nil
    }

    // MARK: - The README's screenshots

    /// Writes the feature's PNGs, on the stand-in wallpaper the README's own
    /// panel render uses. Opt-in: does nothing unless
    /// `CREATIVENOTCH_RENDER_FEATURES` is set.
    @Test func exportFeatureRenders() throws {
        guard ProcessInfo.processInfo.environment["CREATIVENOTCH_RENDER_FEATURES"] != nil else { return }
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/assets/features", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let running = Countdown(duration: 25 * 60, startingAt: Date(timeIntervalSinceReferenceDate: -7 * 60))

        // The dropper, waiting in the header.
        let header = PanelRenderingTests.state()
        header.countdown = running
        header.transition(to: .open(.timer))
        try Self.write(header, to: directory.appendingPathComponent("color-picker-header.png"))

        // The first pick: one colour, copied as hex.
        let first = Self.picked(PanelRenderingTests.state(), history: [Self.picks[0]])
        first.countdown = running
        try Self.write(first, to: directory.appendingPathComponent("color-picker-picked.png"))

        // A few picks later: the recent swatches, each a click from the
        // pasteboard again.
        let history = Self.picked(PanelRenderingTests.state())
        history.countdown = running
        try Self.write(history, to: directory.appendingPathComponent("color-picker-history.png"))

        // "Copy as SwiftUI", at the Large text size.
        let screen = TextSizeRenderingTests.state(.large)
        let swift = Self.picked(screen, history: Array(Self.picks.prefix(3)), format: .swiftUI)
        swift.countdown = running
        try Self.write(swift, to: directory.appendingPathComponent("color-picker-swiftui-large.png"))
    }

    /// The panel at 2x over a soft gradient, the README render's look.
    static func write(_ s: AppState, to url: URL) throws {
        let size = s.panelFrame.size
        let content = ZStack {
            LinearGradient(
                colors: [Color(red: 0.36, green: 0.42, blue: 0.86), Color(red: 0.86, green: 0.52, blue: 0.74)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            NotchRootView(app: s, now: Date(timeIntervalSinceReferenceDate: 0))
        }
        .frame(width: size.width, height: size.height)
        .environment(\.animatesEqualizer, false)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let rep = NSBitmapImageRep(cgImage: image)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: url)
    }
}
