import Testing
import CoreGraphics
@testable import CreativeNotchCore

/// The lyrics line's geometry (spec 2026-10-29, "Where lyrics show").
///
/// The strip is part of the closed shape, so it grows through
/// `NotchShape.visibleRect` like a badge does: the drawn rect, the hit test
/// and the hover tracking rect all read that one function, and a strip that
/// grew only the drawing would be a line of text that clicks fall through.
struct LyricsShapeTests {

    // A real 14" MacBook: 179pt notch, 32pt menu bar (as MediaPeekShapeTests).
    private let notch = Anchor.notch(CGRect(x: 646, y: 924, width: 179, height: 32))
    private let pill = Anchor.pill(CGRect(x: 500, y: 900, width: 180, height: 32))
    private let panel = CGRect(x: 425, y: 696, width: 620, height: 260)
    private let pillPanel = CGRect(x: 280, y: 672, width: 620, height: 260)
    private let line = NotchGeometry.lyricsLineHeight

    @Test func withoutALineNothingChanges() {
        for presentation in [NotchShape.Presentation.closed, .mediaPeek, .statusPeek, .peek, .expanded] {
            let plain = NotchShape.visibleRect(presentation: presentation, anchor: notch, panelFrame: panel, badgeWidth: 68)
            let none = NotchShape.visibleRect(presentation: presentation, anchor: notch, panelFrame: panel, badgeWidth: 68, lyricsHeight: 0)
            #expect(plain == none)
        }
    }

    /// Pinned to literals: the strip hangs below the notch and its badge,
    /// flush with the screen's top edge, as wide as the closed shape.
    @Test func theClosedNotchGrowsDownByOneLine() {
        let r = NotchShape.visibleRect(
            presentation: .closed, anchor: notch, panelFrame: panel,
            badgeWidth: 68, lyricsHeight: line
        )
        #expect(r == CGRect(x: 221, y: 228 - line, width: 179 + 68, height: 32 + line))
    }

    /// A pill sits inside the menu bar, and a shape grown down from it would
    /// be as wide as the line at the menu bar's height too — over the app
    /// menus "Keep clear of app menus" exists to protect. So a pill shows
    /// lyrics in the peek and the panel, never as a strip.
    @Test func aPillNeverGrowsAStrip() {
        let plain = NotchShape.visibleRect(presentation: .closed, anchor: pill, panelFrame: pillPanel, badgeWidth: 68)
        let lined = NotchShape.visibleRect(presentation: .closed, anchor: pill, panelFrame: pillPanel, badgeWidth: 68, lyricsHeight: line)
        #expect(lined == plain)
    }

    @Test func theMusicPeekGrowsByOneLineToo() {
        for (anchor, frame) in [(notch, panel), (pill, pillPanel)] {
            let plain = NotchShape.visibleRect(presentation: .mediaPeek, anchor: anchor, panelFrame: frame)
            let lined = NotchShape.visibleRect(presentation: .mediaPeek, anchor: anchor, panelFrame: frame, lyricsHeight: line)
            #expect(lined.maxY == plain.maxY)
            #expect(lined.width == plain.width && lined.minX == plain.minX)
            #expect(lined.height == plain.height + line)
            #expect(CGRect(origin: .zero, size: frame.size).contains(lined))
        }
    }

    /// Only the music states carry lyrics.
    @Test func otherPresentationsIgnoreTheLine() {
        for presentation in [NotchShape.Presentation.statusPeek, .peek, .expanded] {
            let plain = NotchShape.visibleRect(presentation: presentation, anchor: notch, panelFrame: panel)
            let lined = NotchShape.visibleRect(presentation: presentation, anchor: notch, panelFrame: panel, lyricsHeight: line)
            #expect(lined == plain)
        }
    }

    /// Below the 33pt menu bar, a 22pt strip covers the top of a window's
    /// title bar or a browser's tab strip, never deeper.
    @Test func theLineIsOneLineTall() {
        #expect(line == 22)
    }
}
