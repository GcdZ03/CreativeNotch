import Testing
import CoreGraphics
@testable import CreativeNotchCore

/// The closed panel used to be drawn with square corners. On a real notch
/// that paints black over the pixels *outside* the hardware's rounded
/// bottom corners but inside its bounding box — so instead of vanishing
/// into the housing, the panel showed as a hard-edged black rectangle with
/// two sharp corners against the desktop.
///
/// Radii live here, beside `visibleRect`, rather than as literals in the
/// view: the panel's shape and its rounding are the same decision, and
/// this project's only Critical bug came from deriving one rectangle two
/// different ways.
struct NotchCornerRadiiTests {

    private let notch = Anchor.notch(CGRect(x: 646, y: 924, width: 179, height: 32))
    private let pill = Anchor.pill(CGRect(x: 500, y: 900, width: 180, height: 32))

    /// The bug in the screenshot.
    @Test func aClosedNotchRoundsItsBottomCorners() {
        let r = NotchShape.cornerRadii(presentation: .closed, anchor: notch)
        #expect(r.bottomLeading > 0)
        #expect(r.bottomTrailing > 0)
    }

    /// Anything anchored to a physical notch is flush with the top edge of
    /// the screen. Rounding there would leave two wedges of desktop
    /// showing above the panel, which is the same artefact upside down.
    @Test func nothingOnANotchEverRoundsItsTopCorners() {
        for presentation in [NotchShape.Presentation.closed, .peek, .expanded] {
            let r = NotchShape.cornerRadii(presentation: presentation, anchor: notch)
            #expect(r.topLeading == 0, "\(presentation) rounded the top")
            #expect(r.topTrailing == 0, "\(presentation) rounded the top")
        }
    }

    /// The closed radius approximates the hardware cutout, so it is not
    /// the same number as the panel's own corner styling.
    @Test func theClosedRadiusMatchesTheHardwareConstant() {
        let r = NotchShape.cornerRadii(presentation: .closed, anchor: notch)
        #expect(r.bottomLeading == NotchGeometry.notchCornerRadius)
        #expect(r.bottomTrailing == NotchGeometry.notchCornerRadius)
    }

    /// Erring large is safe and erring small is not: too small leaves the
    /// black corners in the screenshot, too large just reveals desktop
    /// pixels the panel was never meant to cover.
    @Test func theClosedRadiusIsLargeEnoughToClearTheHousing() {
        #expect(NotchGeometry.notchCornerRadius >= 8)
    }

    /// A notchless Mac's pill floats below the menu bar with nothing to
    /// merge into, so it stays rounded all the way round.
    @Test func aPillIsRoundedOnEveryCorner() {
        let r = NotchShape.cornerRadii(presentation: .closed, anchor: pill)
        #expect(r.topLeading == r.bottomLeading)
        #expect(r.topTrailing == r.bottomTrailing)
        #expect(r.topLeading > 0)
    }
}
