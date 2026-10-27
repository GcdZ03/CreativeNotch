import CoreGraphics
import Testing
import CreativeNotchCore

/// Which way the panel gets to a new geometry (2026-10-28): placed at once on
/// the display it is on, faded across to another one.
///
/// The displays are the owner's desk, in AppKit coordinates: the notched
/// built-in at the origin, a 1920-wide landscape display directly above it,
/// a portrait one to its right. Written out rather than derived through
/// `NotchGeometry`, so the geometry code is never the thing handing a test
/// the rectangles it is checked against.
struct PanelMoveTests {

    private static let builtIn = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private static let landscape = CGRect(x: -408, y: 982, width: 1920, height: 1080)
    private static let portrait = CGRect(x: 1512, y: 69, width: 1080, height: 1920)

    /// The built-in's notch: flush with the top of the display, so its top
    /// edge is the bottom edge of the landscape display above it.
    private static let notch = Anchor.notch(CGRect(x: 662, y: 952, width: 185, height: 30))
    private static let notchFrame = CGRect(x: 444, y: 722, width: 620, height: 260)

    private static let landscapePill = Anchor.pill(CGRect(x: 462, y: 2036, width: 180, height: 24))
    private static let landscapeFrame = CGRect(x: 242, y: 1800, width: 620, height: 260)

    private static let portraitPill = Anchor.pill(CGRect(x: 1962, y: 1963, width: 180, height: 24))
    private static let portraitFrame = CGRect(x: 1742, y: 1727, width: 620, height: 260)

    private func move(
        _ from: Anchor, _ fromFrame: CGRect,
        to: Anchor, _ toFrame: CGRect, on screen: CGRect,
        reduceMotion: Bool = false
    ) -> PanelMove {
        PanelMove.from(from, frame: fromFrame, to: to, frame: toFrame, on: screen, reduceMotion: reduceMotion)
    }

    // MARK: - Nothing to do

    /// A switch to an app on the display the panel is already on asks for
    /// the same geometry; nothing moves and nothing fades.
    @Test func theSameGeometryStays() {
        #expect(move(Self.notch, Self.notchFrame, to: Self.notch, Self.notchFrame, on: Self.builtIn) == .stay)
    }

    // MARK: - Another display

    @Test func theNotchGoingToAnotherDisplayFadesAcross() {
        #expect(move(Self.notch, Self.notchFrame, to: Self.landscapePill, Self.landscapeFrame, on: Self.landscape)
                == .betweenDisplays(.standard))
        #expect(move(Self.landscapePill, Self.landscapeFrame, to: Self.portraitPill, Self.portraitFrame, on: Self.portrait)
                == .betweenDisplays(.standard))
        #expect(move(Self.portraitPill, Self.portraitFrame, to: Self.notch, Self.notchFrame, on: Self.builtIn)
                == .betweenDisplays(.standard))
    }

    /// The built-in's panel ends where the landscape display above it begins.
    /// Counting a shared edge as overlapping would call the trip up to the
    /// landscape display a move on the spot, and the notch would jump there
    /// unannounced.
    @Test func aDisplayTouchingThePanelIsStillAnotherDisplay() {
        #expect(Self.landscape.minY == Self.notchFrame.maxY)
        #expect(move(Self.notch, Self.notchFrame, to: Self.landscapePill, Self.landscapeFrame, on: Self.landscape)
                != .inPlace)
    }

    /// Unplugged, the display the panel was on is gone, and wherever it lands
    /// is somewhere else.
    @Test func leavingADisplayThatWentAwayFadesIn() {
        let gone = Anchor.pill(CGRect(x: 4000, y: 1400, width: 180, height: 24))
        let goneFrame = CGRect(x: 3780, y: 1164, width: 620, height: 260)
        #expect(move(gone, goneFrame, to: Self.notch, Self.notchFrame, on: Self.builtIn)
                == .betweenDisplays(.standard))
    }

    // MARK: - The same display

    /// Keeping clear of the menus slides the pill along its own bar: no trip.
    @Test func thePillMovingAlongItsOwnBarIsInPlace() {
        let cleared = Anchor.pill(CGRect(x: 700, y: 2036, width: 180, height: 24))
        let clearedFrame = CGRect(x: 480, y: 1800, width: 620, height: 260)
        #expect(move(Self.landscapePill, Self.landscapeFrame, to: cleared, clearedFrame, on: Self.landscape)
                == .inPlace)
    }

    /// A new text size is a new frame around the same anchor.
    @Test func aNewFrameAroundTheSameAnchorIsInPlace() {
        let larger = CGRect(x: 212, y: 1760, width: 680, height: 300)
        #expect(move(Self.landscapePill, Self.landscapeFrame, to: Self.landscapePill, larger, on: Self.landscape)
                == .inPlace)
    }

    /// The landscape display switched to 1680x1050, as measured on the desk:
    /// macOS kept its bottom edge on the built-in and brought its top down
    /// 30pt. Its frame, and so its metrics, changed, and the pill's old centre
    /// is now above it, but it is the display the pill was on. Comparing the
    /// metrics, or asking for the old centre, would fade the pill out and
    /// back in on the spot.
    @Test func aModeChangeIsTheSameDisplay() {
        let narrower = CGRect(x: -408, y: 982, width: 1680, height: 1050)
        #expect(narrower.contains(CGPoint(x: Self.landscapePill.rect.midX, y: Self.landscapePill.rect.midY)) == false)
        let recentred = Anchor.pill(CGRect(x: 342, y: 2006, width: 180, height: 24))
        let recentredFrame = CGRect(x: 122, y: 1770, width: 620, height: 260)
        #expect(move(Self.landscapePill, Self.landscapeFrame, to: recentred, recentredFrame, on: narrower)
                == .inPlace)
    }

    /// The notch becoming a pill on the display it is on is a change of
    /// shape, not of display.
    @Test func theNotchBecomingAPillOnItsOwnDisplayIsInPlace() {
        let pill = Anchor.pill(CGRect(x: 666, y: 956, width: 180, height: 24))
        let pillFrame = CGRect(x: 446, y: 720, width: 620, height: 260)
        #expect(move(Self.notch, Self.notchFrame, to: pill, pillFrame, on: Self.builtIn) == .inPlace)
    }

    // MARK: - The trip itself

    /// Out, then in with a drop of a few points from the top edge, and the
    /// whole trip well under the ~0.35s a move may take before it reads as
    /// slow.
    @Test func theTripIsShortAndDropsIn() {
        let trip = DisplayHandoff.standard
        #expect(trip.fadeOut > 0)
        #expect(trip.fadeIn > trip.fadeOut)
        #expect(trip.fadeOut + trip.fadeIn <= 0.3)
        #expect(trip.drop > 0 && trip.drop <= 8)
    }

    /// Reduce Motion: a plain short fade, nothing travels.
    @Test func reduceMotionFadesWithoutTravelling() {
        let trip = DisplayHandoff.reduced
        #expect(trip.drop == 0)
        #expect(trip.fadeOut > 0 && trip.fadeIn > 0)
        #expect(trip.fadeOut + trip.fadeIn <= 0.3)
        #expect(move(Self.notch, Self.notchFrame, to: Self.landscapePill, Self.landscapeFrame,
                     on: Self.landscape, reduceMotion: true)
                == .betweenDisplays(.reduced))
    }
}
