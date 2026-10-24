import AppKit
import SwiftUI
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// That each layout option draws what it says (2026-10-24), offscreen, with
/// the geometry the app would give it on a 14" MacBook Pro -- a 190×32 notch
/// on a 1512-wide screen -- and every tab showing, the widest the tab bar
/// gets.
///
/// Pixel checks in the shape `PanelRenderingTests` set out: render
/// `NotchRootView`, ask where the ink is. "Ink" is lit pixels; "cover" is
/// any opaque pixel, black included, for the corners and the closed notch,
/// whose shape is black on transparent.
///
/// The last test writes the README's screenshots, and only when asked:
/// `CREATIVENOTCH_WRITE_SCREENSHOTS=1 swift test --filter LayoutRenderingTests`.
@MainActor
struct LayoutRenderingTests {

    static let screen = TextSizeRenderingTests.screen

    static func state(
        _ options: LayoutOptions = .default, size: TextSize = .standard, tabCount: Int = 5
    ) -> AppState {
        let s = AppState()
        s.textSize = size
        s.layoutOptions = options
        let anchor = NotchGeometry.anchor(for: screen)
        s.setGeometry(
            anchor: anchor,
            panelFrame: NotchGeometry.panelFrame(
                for: anchor, in: screen, textScale: size.scale, width: options.width, tabCount: tabCount
            )
        )
        s.hasBattery = true
        s.showsMediaControls = true
        s.power = PowerSnapshot(level: 67, source: .battery, isCharging: false, isLowPowerMode: false)
        s.nowPlaying = TrackSnapshot(
            title: "Blinding Lights", artist: "The Weeknd", isPlaying: false,
            position: PlaybackPosition(elapsed: 100, duration: 200, anchoredAt: Date(timeIntervalSince1970: 0))
        )
        return s
    }

    static func bitmap(_ s: AppState) -> NSBitmapImageRep? {
        TextSizeRenderingTests.bitmap(s)
    }

    /// Whether the pixel at `point` (top-left origin) is drawn at all.
    static func covered(_ b: NSBitmapImageRep, _ point: CGPoint) -> Bool {
        (b.colorAt(x: Int(point.x), y: Int(point.y))?.alphaComponent ?? 0) > 0.5
    }

    /// The left ear, header band only, between the first button slot and
    /// the housing: tabs fill it, a lone gear does not.
    static func leftEarPastFirstButton(_ s: AppState) -> CGRect {
        let ear = s.anchor.rect.minX - s.panelFrame.minX
        return CGRect(x: 60, y: 2, width: ear - 66, height: s.anchor.rect.height - 4)
    }

    // MARK: - Tabs side

    /// Right puts the tabs in the right ear: with the battery hidden and
    /// the colour picker off, the left ear holds only the gear at its outer
    /// edge.
    @Test func tabsOnTheRightLeaveTheLeftEarToTheGear() throws {
        let left = Self.state(LayoutOptions(showsBattery: false))
        left.preferences.colorPicker = false
        left.transition(to: .open(.timer))
        let right = Self.state(LayoutOptions(tabsSide: .right, showsBattery: false))
        right.preferences.colorPicker = false
        right.transition(to: .open(.timer))

        let l = try #require(Self.bitmap(left))
        let r = try #require(Self.bitmap(right))
        #expect(PanelRenderingTests.ink(l, in: Self.leftEarPastFirstButton(left)) > 0.01, "control: tabs on the left")
        #expect(PanelRenderingTests.ink(r, in: Self.leftEarPastFirstButton(right)) == 0, "tabs still on the left")
        // The tabs arrived on the right, and nothing went behind the camera.
        let rightEar = CGRect(x: 405 + 6, y: 2, width: 215 - 60, height: 28)
        #expect(PanelRenderingTests.ink(r, in: rightEar) > 0.01)
        #expect(PanelRenderingTests.ink(r, in: TextSizeRenderingTests.housing(right)) == 0)
    }

    /// The colour picker's dropper is a status item, so it moves with the
    /// status ear: left of the camera with the tabs on the right, still
    /// nearest the housing, the gear still at the outer edge. Measured as
    /// the difference the picker makes, battery hidden, so the tabs and the
    /// gear cancel out.
    @Test func theEyedropperMovesWithTheStatusEar() throws {
        func render(side: EarSide, picker: Bool) throws -> (NSBitmapImageRep, AppState) {
            let s = Self.state(LayoutOptions(tabsSide: side, showsBattery: false))
            s.preferences.colorPicker = picker
            s.transition(to: .open(.timer))
            return (try #require(Self.bitmap(s)), s)
        }
        let (rightOn, s) = try render(side: .right, picker: true)
        let (rightOff, _) = try render(side: .right, picker: false)
        let leftEar = s.anchor.rect.minX - s.panelFrame.minX
        // Gear at 12...46 from the left edge; the dropper one gap past it.
        let dropperSlot = CGRect(x: 52, y: 2, width: 42, height: 28)
        let outerSlot = CGRect(x: 8, y: 2, width: 42, height: 28)
        #expect(PanelRenderingTests.ink(rightOn, in: dropperSlot) > 0.01, "dropper missing from the left ear")
        #expect(PanelRenderingTests.ink(rightOff, in: dropperSlot) == 0, "control: nothing there without it")
        #expect(PanelRenderingTests.ink(rightOn, in: outerSlot) > 0.01, "gear left the outer edge")
        #expect(PanelRenderingTests.ink(rightOn, in: TextSizeRenderingTests.housing(s)) == 0)
        #expect(dropperSlot.maxX < leftEar)

        // And with the tabs on the left, it is in the right ear, not the left.
        let (leftOn, l) = try render(side: .left, picker: true)
        let (leftOff, _) = try render(side: .left, picker: false)
        let rightEarStart = l.anchor.rect.maxX - l.panelFrame.minX
        let rightEar = CGRect(x: rightEarStart + 2, y: 2, width: l.panelFrame.width - rightEarStart - 4, height: 28)
        #expect(PanelRenderingTests.ink(leftOn, in: rightEar) > PanelRenderingTests.ink(leftOff, in: rightEar))
    }

    // MARK: - Battery

    /// Hidden, the battery cell's place beside the gear is empty.
    @Test func hidingTheBatteryEmptiesItsCell() throws {
        let cell = CGRect(x: 405 + 40, y: 2, width: 120, height: 28)
        // The colour picker off: its dropper sits beside the battery.
        let shown = Self.state()
        shown.preferences.colorPicker = false
        shown.transition(to: .open(.timer))
        let hidden = Self.state(LayoutOptions(showsBattery: false))
        hidden.preferences.colorPicker = false
        hidden.transition(to: .open(.timer))
        #expect(PanelRenderingTests.ink(try #require(Self.bitmap(shown)), in: cell) > 0.01, "control: cell drawn")
        #expect(PanelRenderingTests.ink(try #require(Self.bitmap(hidden)), in: cell) == 0)
    }

    // MARK: - Width

    /// Every width, every text size, both sides, five tabs: nothing lands
    /// behind the camera housing.
    @Test(arguments: PanelWidth.allCases)
    func theHeaderStaysOutOfTheHousingAtEveryWidth(width: PanelWidth) throws {
        for size in TextSize.allCases {
            for side in EarSide.allCases {
                let s = Self.state(LayoutOptions(width: width, tabsSide: side), size: size)
                s.transition(to: .open(.timer))
                let b = try #require(Self.bitmap(s))
                #expect(PanelRenderingTests.ink(b, in: TextSizeRenderingTests.housing(s)) == 0,
                        "\(width) at \(size), tabs \(side): something behind the housing")
            }
        }
    }

    /// Compact and Wide hold every pane without running off the bottom, the
    /// check `TextSizeRenderingTests` makes for the default width.
    @Test(arguments: [PanelWidth.compact, .wide])
    func nothingRunsOffTheBottomAtThisWidth(width: PanelWidth) throws {
        for size in TextSize.allCases {
            for pane in TextSizeRenderingTests.panes {
                let s = Self.state(LayoutOptions(width: width), size: size)
                pane.apply(s)
                let b = try #require(Self.bitmap(s))
                #expect(TextSizeRenderingTests.stripInk(b, s) == 0,
                        "\(pane.name) at \(width), \(size) runs off the bottom")
            }
        }
    }

    /// Compact is narrower and Wide wider than Default, in the render too.
    @Test func theWidthsRenderAtTheirWidths() throws {
        let widths = try PanelWidth.allCases.map { width -> Int in
            let s = Self.state(LayoutOptions(width: width))
            s.transition(to: .open(.timer))
            return try #require(Self.bitmap(s)).pixelsWide
        }
        #expect(widths == [602, 620, 720])
    }

    // MARK: - Corners

    /// Near the bottom-left corner: Round leaves a pixel Default covers, and
    /// Default leaves one Tight covers.
    @Test func theCornerStyleRoundsTheOpenPanel() throws {
        func bitmap(_ corners: PanelCorners) throws -> (NSBitmapImageRep, CGFloat) {
            let s = Self.state(LayoutOptions(corners: corners))
            s.transition(to: .open(.timer))
            return (try #require(Self.bitmap(s)), s.panelFrame.height)
        }
        let (tight, h) = try bitmap(.tight)
        let (standard, _) = try bitmap(.standard)
        let (round, _) = try bitmap(.round)
        let inner = CGPoint(x: 7, y: h - 7)
        let outer = CGPoint(x: 4, y: h - 4)
        #expect(Self.covered(standard, inner))
        #expect(!Self.covered(round, inner))
        #expect(Self.covered(tight, outer))
        #expect(!Self.covered(standard, outer))
    }

    // MARK: - Badges

    /// A running countdown grows the closed notch by its badge; hidden, the
    /// notch stays the housing's own width.
    @Test func aHiddenTimerBadgeLeavesTheClosedNotchBare() throws {
        let countdown = Countdown(duration: 25 * 60, startingAt: Date(timeIntervalSinceReferenceDate: -90))
        let shown = Self.state()
        shown.countdown = countdown
        let hidden = Self.state(LayoutOptions(showsTimerBadge: false))
        hidden.countdown = countdown
        let ear = shown.anchor.rect.maxX - shown.panelFrame.minX
        let badge = CGPoint(x: ear + 20, y: 16)
        #expect(Self.covered(try #require(Self.bitmap(shown)), badge), "control: badge drawn")
        #expect(!Self.covered(try #require(Self.bitmap(hidden)), badge))
    }

    // MARK: - Screenshots

    /// Writes `docs/assets/features/notch-layout-*.png`: each option in the
    /// open panel, on a stand-in wallpaper under a 14" notch, at 2×. Opt-in,
    /// so the normal suite never rewrites files in the repo.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CREATIVENOTCH_WRITE_SCREENSHOTS"] == "1"))
    func writeScreenshots() throws {
        let out = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/assets/features")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        // A running countdown rather than the idle tab: `ImageRenderer` draws
        // the idle tab's minutes field, an AppKit text field, as a placeholder.
        let running: (AppState) -> Void = {
            $0.countdown = Countdown(duration: 25 * 60, startingAt: Date(timeIntervalSinceReferenceDate: -7 * 60))
            $0.transition(to: .open(.timer))
        }
        let shots: [(String, LayoutOptions, (AppState) -> Void)] = [
            ("default", .default, running),
            ("compact", LayoutOptions(width: .compact), running),
            ("wide", LayoutOptions(width: .wide), running),
            ("tabs-right", LayoutOptions(tabsSide: .right), running),
            ("no-battery", LayoutOptions(showsBattery: false), running),
            ("corners-round", LayoutOptions(corners: .round), running),
            ("corners-tight", LayoutOptions(corners: .tight), running),
        ]
        for (name, options, apply) in shots {
            let s = Self.state(options)
            apply(s)
            try Self.writePNG(Self.scene(s, canvasHeight: 300), to: out.appendingPathComponent("notch-layout-\(name).png"))
        }

        // The closed notch with a countdown running: badge shown, then hidden.
        let countdown = Countdown(duration: 25 * 60, startingAt: Date(timeIntervalSinceReferenceDate: -7 * 60))
        let shown = Self.state()
        shown.countdown = countdown
        let hidden = Self.state(LayoutOptions(showsTimerBadge: false))
        hidden.countdown = countdown
        let pair = VStack(spacing: 0) {
            Self.scene(shown, canvasHeight: 56, label: "Timer badge on")
            Self.scene(hidden, canvasHeight: 56, label: "Timer badge off")
        }
        try Self.writePNG(pair, to: out.appendingPathComponent("notch-layout-badges.png"))
    }

    /// The canvas: a 900pt slice of the screen centred on the notch, wide
    /// enough that Compact, Default and Wide read as different sizes.
    static let canvasWidth: CGFloat = 900

    /// The panel on a stand-in wallpaper and menu bar, where it would sit.
    static func scene(_ s: AppState, canvasHeight: CGFloat, label: String? = nil) -> some View {
        let canvasMinX = s.anchor.rect.midX - canvasWidth / 2
        let size = s.panelFrame.size
        let band = s.anchor.rect.height
        return ZStack(alignment: .topLeading) {
            // Vertical only, so every row of the PNG is one colour and the
            // file stays small.
            LinearGradient(
                colors: [Color(red: 0.30, green: 0.34, blue: 0.66), Color(red: 0.74, green: 0.46, blue: 0.68)],
                startPoint: .top, endPoint: .bottom
            )
            // The menu bar, translucent over the wallpaper.
            Rectangle().fill(.white.opacity(0.18)).frame(height: band)
            // The camera housing itself, under whatever the panel draws.
            UnevenRoundedRectangle(
                bottomLeadingRadius: NotchGeometry.notchCornerRadius,
                bottomTrailingRadius: NotchGeometry.notchCornerRadius,
                style: .continuous
            )
            .fill(.black)
            .frame(width: s.anchor.rect.width, height: band)
            .offset(x: s.anchor.rect.minX - canvasMinX)
            NotchRootView(app: s, now: Date(timeIntervalSinceReferenceDate: 0))
                .frame(width: size.width, height: size.height)
                .offset(x: s.panelFrame.minX - canvasMinX)
                .environment(\.animatesEqualizer, false)
            if let label {
                Text(label)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(height: band)
                    .padding(.leading, 16)
            }
        }
        .frame(width: canvasWidth, height: canvasHeight, alignment: .topLeading)
        .clipped()
    }

    static func writePNG(_ view: some View, to url: URL) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try png.write(to: url)
    }
}
