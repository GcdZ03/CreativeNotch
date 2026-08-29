import Testing
import CoreGraphics
@testable import CreativeNotchCore

/// On a real notch the peek used to be a 320x44 slab centred on the notch
/// and top-aligned with it — which put 72% of the level bar *behind the
/// camera housing*, and the content's vertical centre inside the notch's
/// own band. Measured on a 14" MacBook: a 179x32 notch, a 320pt peek, and
/// only two 70pt slivers of bar actually visible.
///
/// The peek now spans the notch plus an ear either side, so the icon and
/// the bar sit in the ears and the physical notch is left alone.
struct NotchEarLayoutTests {

    // A real 14" MacBook: 179pt notch, 32pt menu bar.
    private let notch = Anchor.notch(CGRect(x: 646, y: 924, width: 179, height: 32))
    private let panel = CGRect(x: 425, y: 696, width: 620, height: 260)

    private func peek(_ anchor: Anchor) -> CGRect {
        NotchShape.visibleRect(presentation: .peek, anchor: anchor, panelFrame: panel)
    }

    @Test func thePeekAddsAnEarOnEachSideOfTheNotch() {
        let r = peek(notch)
        #expect(r.width == 179 + NotchGeometry.peekEarWidth * 2)
    }

    /// The whole point: the notch's own band must be inside the peek, so
    /// the ears sit either side of it rather than the panel straddling it
    /// at some arbitrary offset.
    @Test func theNotchSitsExactlyCentredWithinThePeek() {
        let r = peek(notch)
        let local = CGRect(x: 646 - 425, y: 924 - 696, width: 179, height: 32)
        #expect(r.minX == local.minX - NotchGeometry.peekEarWidth)
        #expect(r.maxX == local.maxX + NotchGeometry.peekEarWidth)
        #expect(local.midX == r.midX)
    }

    /// The peek must not grow taller than the notch, or it would hang
    /// below the menu bar and stop reading as part of the notch.
    @Test func thePeekIsExactlyAsTallAsTheNotch() {
        let r = peek(notch)
        #expect(r.height == 32)
        // Flush with the notch's own bottom edge, in panel-local space.
        let notchLocalMinY = notch.rect.minY - panel.minY
        #expect(r.minY == notchLocalMinY)
    }

    /// Each ear must be wide enough to hold what goes in it — an 18pt icon
    /// on the left, a level bar on the right — with room to breathe.
    @Test func eachEarIsWideEnoughForItsContent() {
        #expect(NotchGeometry.peekEarWidth >= 90)
    }

    /// A notchless Mac has no camera housing to avoid, so its peek keeps
    /// the original centred slab. Regressing this would make the pill
    /// sprout two empty ears around nothing.
    @Test func aPillPeekIsUnchanged() {
        let pill = Anchor.pill(CGRect(x: 500, y: 900, width: 180, height: 32))
        let r = peek(pill)
        #expect(r.width == NotchGeometry.peekSize.width)
        #expect(r.height == NotchGeometry.peekSize.height)
    }

    /// The peek is drawn inside the window, so it has to fit in it.
    @Test func thePeekFitsInsideThePanel() {
        let r = peek(notch)
        #expect(r.minX >= 0)
        #expect(r.maxX <= panel.width)
    }
}
