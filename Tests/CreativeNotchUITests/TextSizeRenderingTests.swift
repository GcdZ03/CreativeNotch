import AppKit
import SwiftUI
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// That scaled text fits the panel it is drawn in (2026-10-24).
///
/// Rendered offscreen at each size, with the geometry the app would give it
/// -- `NotchGeometry.panelFrame(for:in:textScale:)` on a 14" MacBook Pro
/// screen -- and with every pane at its fullest: a track with a position and
/// controls in the music column, the welcome card, the timer running.
///
/// **What "does not clip" means here.** Every body in the panel is pinned to
/// the top and clipped to the shape, so content too tall for it runs off the
/// bottom: the last few points above the bottom hairline, which every pane
/// pads clear, light up. `largerTextInTheOldPanelIsCaught` is the control:
/// the same content at the largest size in the panel's *default* frame does
/// light them, so a pass below means the geometry grew enough, not that the
/// check cannot see.
///
/// `ImageRenderer` does not run `ScrollView` content (see
/// `PanelRenderingTests`), so the shelf's tiles and the clipboard's rows are
/// not drawn here; their lengths come from the same `NotchType.length` the
/// column uses.
@MainActor
struct TextSizeRenderingTests {

    /// 14" MacBook Pro: a 190×32 notch centred on a 1512-wide screen.
    static let screen = ScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        safeAreaTopInset: 32, auxiliaryTopLeftWidth: 661, auxiliaryTopRightWidth: 661, menuBarHeight: 32
    )

    /// `geometry` overrides the panel's own scale, for the control.
    static func state(_ size: TextSize, geometry: CGFloat? = nil) -> AppState {
        let s = AppState()
        s.textSize = size
        let anchor = NotchGeometry.anchor(for: screen)
        s.setGeometry(
            anchor: anchor,
            panelFrame: NotchGeometry.panelFrame(for: anchor, in: screen, textScale: geometry ?? size.scale)
        )
        s.hasBattery = true
        s.showsMediaControls = true
        s.power = PowerSnapshot(level: 67, source: .battery, isCharging: false, isLowPowerMode: false)
        // Paused, so the bar sits at a fixed place whatever the wall clock says.
        s.nowPlaying = TrackSnapshot(
            title: "Blinding Lights", artist: "The Weeknd", isPlaying: false,
            position: PlaybackPosition(elapsed: 100, duration: 200, anchoredAt: Date(timeIntervalSince1970: 0))
        )
        return s
    }

    static func bitmap(_ s: AppState) -> NSBitmapImageRep? {
        let size = s.panelFrame.size
        let renderer = ImageRenderer(
            content: NotchRootView(app: s, now: Date(timeIntervalSinceReferenceDate: 0))
                .frame(width: size.width, height: size.height)
        )
        renderer.scale = 1
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)
    }

    /// The strip every pane keeps clear: above the 1pt hairline, inside the
    /// rounded corners, either side of the music column's divider -- which
    /// runs the body's full height on purpose.
    static func bottomStrip(_ s: AppState) -> [CGRect] {
        let size = s.panelFrame.size
        let divider = PanelLayout.resolve(
            anchor: s.anchor, panelFrame: s.panelFrame, showsMedia: true, textScale: s.textSize.scale
        ).mediaColumnWidth
        let y = size.height - 9
        return [
            CGRect(x: 24, y: y, width: divider - 2 - 24, height: 7),
            CGRect(x: divider + 2, y: y, width: size.width - 24 - divider - 2, height: 7),
        ]
    }

    /// Lit pixels in the strip, as a fraction.
    static func stripInk(_ b: NSBitmapImageRep, _ s: AppState) -> Double {
        bottomStrip(s).map { PanelRenderingTests.ink(b, in: $0) }.max() ?? 0
    }

    /// The camera housing, panel-local, top-left origin, inside the header.
    static func housing(_ s: AppState) -> CGRect {
        let gap = s.anchor.rect.minX - s.panelFrame.minX
        return CGRect(x: gap + 5, y: 2, width: s.anchor.rect.width - 10, height: s.anchor.rect.height - 4)
    }

    /// Each fullest state the open panel can be in.
    static let panes: [(name: String, apply: (AppState) -> Void)] = [
        ("timer idle", { $0.transition(to: .open(.timer)) }),
        ("timer running", {
            $0.countdown = Countdown(duration: 25 * 60, startingAt: Date(timeIntervalSinceReferenceDate: -90))
            $0.transition(to: .open(.timer))
        }),
        ("battery", { $0.transition(to: .open(.power)) }),
        ("welcome", {
            $0.welcomeSeen = false
            $0.transition(to: .open(.shelf), openedBy: .tap)
        }),
        ("receiving", { $0.transition(to: .receiving) }),
    ]

    @Test(arguments: TextSize.allCases)
    func nothingRunsOffTheBottomOfThePanel(size: TextSize) throws {
        for pane in Self.panes {
            let s = Self.state(size)
            pane.apply(s)
            let b = try #require(Self.bitmap(s))
            #expect(Self.stripInk(b, s) == 0,
                    "\(pane.name) at \(size) runs off the bottom of a \(s.panelFrame.size) panel")
        }
    }

    /// The tabs grow with the text but stay in the ear, clear of the camera.
    @Test(arguments: TextSize.allCases)
    func theHeaderStaysOutOfTheHousing(size: TextSize) throws {
        let s = Self.state(size)
        s.transition(to: .open(.timer))
        let b = try #require(Self.bitmap(s))
        #expect(PanelRenderingTests.ink(b, in: Self.housing(s)) == 0)
    }

    /// The control for the strip check: the largest text in the panel's
    /// default frame does run off it.
    @Test func largerTextInTheOldPanelIsCaught() throws {
        let s = Self.state(.larger, geometry: 1)
        s.transition(to: .open(.timer))
        let b = try #require(Self.bitmap(s))
        #expect(Self.stripInk(b, s) > 0)
    }

    /// The setting actually reaches the panel: the pane's title, "Battery",
    /// draws wider and taller by about the factor. Measured on the title
    /// rather than on the whole pane, whose battery gauge is a fixed graphic.
    @Test func largerTextDrawsLarger() throws {
        func title(_ size: TextSize) throws -> CGSize {
            let s = Self.state(size)
            s.transition(to: .open(.power))
            let b = try #require(Self.bitmap(s))
            let column = PanelLayout.resolve(
                anchor: s.anchor, panelFrame: s.panelFrame, showsMedia: true, textScale: size.scale
            ).mediaColumnWidth
            // The title row: under the header, right of the column, above
            // the pane's content at either size.
            let row = CGRect(
                x: column + 2, y: s.anchor.rect.height + 2,
                width: s.panelFrame.width - column - 26, height: 38
            )
            return Self.inkBounds(b, in: row).size
        }
        let standard = try title(.standard)
        let larger = try title(.larger)
        #expect(standard.width > 20 && standard.height > 6, "no title drawn at the default size")
        #expect(larger.width >= standard.width * 1.2)
        #expect(larger.height >= standard.height * 1.2)
    }

    /// The bounding box of the lit pixels in `rect`, top-left origin.
    static func inkBounds(_ b: NSBitmapImageRep, in rect: CGRect) -> CGRect {
        var box = CGRect.null
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                guard let c = b.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      c.alphaComponent > 0.05,
                      c.redComponent + c.greenComponent + c.blueComponent > 0.15
                else { continue }
                box = box.union(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return box.isNull ? .zero : box
    }

    /// The closed notch's badges and the peeks keep their fixed sizes: they
    /// live in the hardware band and in fixed peek rects. Same geometry,
    /// different setting, same pixels.
    @Test func theBadgesAndPeeksIgnoreTheSetting() throws {
        func render(_ size: TextSize, _ apply: (AppState) -> Void) throws -> Data {
            let s = Self.state(size, geometry: 1)
            apply(s)
            return try #require(Self.bitmap(s)?.tiffRepresentation)
        }
        let countdown = Countdown(duration: 25 * 60, startingAt: Date(timeIntervalSinceReferenceDate: -90))
        let badge: (AppState) -> Void = { $0.countdown = countdown }
        let peek: (AppState) -> Void = {
            $0.transition(to: .peek(.power(.lowPowerMode(enabled: true))))
        }
        #expect(Render.same(try render(.standard, badge), try render(.larger, badge)))
        #expect(Render.same(try render(.standard, peek), try render(.larger, peek)))
    }

    // MARK: - One helper

    /// Every fixed font in the UI goes through `.notchFont`, except in the
    /// files that are deliberately fixed: the closed notch's badges and the
    /// peeks, which live in the hardware band and in fixed peek rects
    /// (`NotchType`), and Settings, a standard window. A new pane that wrote
    /// `.font(.system(size:))` would ignore the setting silently.
    @Test func everyPanelFontGoesThroughTheTypeScale() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/CreativeNotchUI")
        let fixed: Set<String> = [
            "CaptureBadgeView.swift", "TimerBadgeView.swift", "NowPlayingBadgeView.swift",
            "NowPlayingView.swift", "PowerPeekView.swift", "TimerDonePeekView.swift",
            "PreferencesWindow.swift", "LayoutRows.swift", "NotchTypeStyle.swift",
            // Only the peek's fallback label, which no state reaches.
            "NotchRootView.swift",
        ]
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var checked = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            guard !fixed.contains(url.lastPathComponent) else { continue }
            let code = try String(contentsOf: url, encoding: .utf8)
                .split(separator: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            #expect(!code.contains(".system(size:"),
                    "\(url.lastPathComponent) draws a fixed font that ignores Text size; use .notchFont")
            checked += 1
        }
        #expect(checked > 20)
    }
}
