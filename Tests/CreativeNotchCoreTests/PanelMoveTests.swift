import CoreGraphics
import Testing
import CreativeNotchCore

/// Which way the panel gets to a new geometry (2026-10-28): placed at once on
/// the display it is on, or slid along its bar when it is only the same pill
/// further along, and faded across to another one.
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
        reduceMotion: Bool = false,
        drawn: PanelMove.Drawn? = nil
    ) -> PanelMove {
        PanelMove.from(
            from, frame: fromFrame, to: to, frame: toFrame, on: screen,
            reduceMotion: reduceMotion, drawn: drawn
        )
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

    /// Keeping clear of the menus moves the pill along its own bar: no trip,
    /// and the same picture 238pt to the right, so it slides there.
    @Test func thePillMovingAlongItsOwnBarSlides() {
        #expect(move(Self.landscapePill, Self.landscapeFrame, to: Self.cleared, Self.clearedFrame, on: Self.landscape)
                == .slide(.standard))
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
    ///
    /// The capsule is at the top centre of the display before and after, so
    /// nothing on the display moved, and it is placed at once (2026-10-28).
    @Test func aModeChangeIsTheSameDisplay() {
        let narrower = CGRect(x: -408, y: 982, width: 1680, height: 1050)
        #expect(narrower.contains(CGPoint(x: Self.landscapePill.rect.midX, y: Self.landscapePill.rect.midY)) == false)
        let recentred = Anchor.pill(CGRect(x: 342, y: 2006, width: 180, height: 24))
        let recentredFrame = CGRect(x: 122, y: 1770, width: 620, height: 260)
        let capsule = CGRect(x: 290, y: 236, width: 40, height: 24)
        let drawn = PanelMove.Drawn(before: capsule, after: capsule, display: Self.landscape)
        #expect(move(Self.landscapePill, Self.landscapeFrame, to: recentred, recentredFrame, on: narrower, drawn: drawn)
                == .inPlace)
    }

    // MARK: - Sliding (2026-10-28)

    /// The landscape pill moved right of a long menu bar, its frame with it.
    private static let cleared = Anchor.pill(CGRect(x: 700, y: 2036, width: 180, height: 24))
    private static let clearedFrame = CGRect(x: 480, y: 1800, width: 620, height: 260)

    /// Reduce Motion: nothing travels, so the pill is placed at once, as it
    /// always was.
    @Test func underReduceMotionTheShiftIsPlacedAtOnce() {
        #expect(move(Self.landscapePill, Self.landscapeFrame, to: Self.cleared, Self.clearedFrame,
                     on: Self.landscape, reduceMotion: true)
                == .inPlace)
    }

    /// A real notch sits around the camera. Its rectangle moves only when the
    /// display changes mode, and a drawn notch sliding there would leave the
    /// hardware one for a quarter of a second.
    @Test func theNotchMovingSidewaysIsPlacedAtOnce() {
        let shifted = Anchor.notch(CGRect(x: 642, y: 952, width: 185, height: 30))
        let shiftedFrame = CGRect(x: 424, y: 722, width: 620, height: 260)
        #expect(move(Self.notch, Self.notchFrame, to: shifted, shiftedFrame, on: Self.builtIn) == .inPlace)
    }

    /// Near the right edge the panel stops at the display's edge while the
    /// pill goes on, so the pill is somewhere else inside the window: moving
    /// the window would not take the drawing to where it ends up, and it does
    /// not slide. Here the window goes 650pt right, and the capsule it showed
    /// at 290pt is 360pt left of the new window: it cannot morph there either,
    /// so it fades on the spot (2026-10-28).
    @Test func aShiftThePanelEdgeStopsIsNoSlide() {
        let farRight = Anchor.pill(CGRect(x: 1150, y: 2036, width: 180, height: 24))
        let clampedFrame = CGRect(x: 892, y: 1800, width: 620, height: 260)
        let drawn = PanelMove.Drawn(
            before: CGRect(x: 290, y: 236, width: 40, height: 24),
            after: CGRect(x: 328, y: 236, width: 40, height: 24),
            display: Self.landscape
        )
        #expect(move(Self.landscapePill, Self.landscapeFrame, to: farRight, clampedFrame,
                     on: Self.landscape, drawn: drawn)
                == .fadeInPlace(.onTheSpot))
    }

    /// A pill of another size -- the menu bar's height changed with it -- is
    /// a new shape, not the same one moved: no slide. The window moved 238pt
    /// with it, so the capsule as it was is 238pt back along the bar inside
    /// the new one, at 52pt, and it morphs from there (pinned, review of #81:
    /// "not a slide" alone passed for any other answer too).
    @Test func aPillOfAnotherSizeIsNoSlide() {
        let taller = Anchor.pill(CGRect(x: 700, y: 2036, width: 180, height: 30))
        #expect(move(Self.landscapePill, Self.landscapeFrame, to: taller, Self.clearedFrame, on: Self.landscape)
                == .morph(AnchorMorph(from: CGRect(x: 52, y: 236, width: 40, height: 24))))
    }

    /// A new frame size with the shift -- a new text size or panel width at
    /// the same moment -- relays the panel out, so the window does not slide.
    /// The capsule morphs along the bar from where it was, as above.
    @Test func aShiftWithANewFrameSizeIsNoSlide() {
        let wider = CGRect(x: 480, y: 1800, width: 680, height: 260)
        #expect(move(Self.landscapePill, Self.landscapeFrame, to: Self.cleared, wider, on: Self.landscape)
                == .morph(AnchorMorph(from: CGRect(x: 52, y: 236, width: 40, height: 24))))
    }

    /// Sideways only. A pill and its frame 30pt lower on a display that did
    /// not move is the same picture lower; a slide is along the bar, never
    /// across the menu bar. Where it was is 30pt above the lower window,
    /// which cannot show it: it fades on the spot.
    @Test func aShiftDownIsNotASlide() {
        let lower = Anchor.pill(CGRect(x: 700, y: 2006, width: 180, height: 24))
        let lowerFrame = CGRect(x: 480, y: 1770, width: 620, height: 260)
        #expect(move(Self.landscapePill, Self.landscapeFrame, to: lower, lowerFrame, on: Self.landscape)
                == .fadeInPlace(.onTheSpot))
    }

    /// Long enough to be seen travelling, short enough to be over before the
    /// eye has gone from the menus to the pill.
    @Test func theSlideIsShort() {
        #expect(PanelSlide.standard.duration >= 0.2)
        #expect(PanelSlide.standard.duration <= 0.3)
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

    // MARK: - The anchor changing on its own display (2026-10-28)

    /// The built-in in a mode without the notch's band: macOS keeps its
    /// bottom edge and its top comes down below the camera, 945pt high. The
    /// menu bar is 30pt, so the pill sits in it, 2pt below the top.
    private static let builtInBelowNotch = CGRect(x: 0, y: 0, width: 1512, height: 945)
    private static let builtInPill = Anchor.pill(CGRect(x: 666, y: 917, width: 180, height: 26))
    private static let builtInPillFrame = CGRect(x: 446, y: 683, width: 620, height: 260)

    /// The closed shapes, panel-local: the notch's own rectangle, and the
    /// idle capsule at the pill's centre.
    private static let closedNotch = CGRect(x: 218, y: 230, width: 185, height: 30)
    private static let closedPill = CGRect(x: 290, y: 234, width: 40, height: 26)

    /// The landscape display's pill in its 30pt menu bar, and with the menu
    /// bar hidden: 32pt tall, 8pt below the top. Its window hangs from the
    /// pill's top, so it comes down 6pt with it.
    private static let inBar = Anchor.pill(CGRect(x: 462, y: 2034, width: 180, height: 26))
    private static let inBarFrame = CGRect(x: 242, y: 1800, width: 620, height: 260)
    private static let belowBar = Anchor.pill(CGRect(x: 462, y: 2022, width: 180, height: 32))
    private static let belowBarFrame = CGRect(x: 242, y: 1794, width: 620, height: 260)
    private static let closedBelowBar = CGRect(x: 290, y: 228, width: 40, height: 32)

    /// Into a notched mode, the pill becomes the notch. Where it was on its
    /// display -- 2pt under the top, which came up 37pt -- is inside the
    /// notch's window, 2pt under its top: the shape morphs from there.
    @Test func thePillBecomingTheNotchOnItsOwnDisplayMorphs() {
        let drawn = PanelMove.Drawn(before: Self.closedPill, after: Self.closedNotch, display: Self.builtInBelowNotch)
        #expect(move(Self.builtInPill, Self.builtInPillFrame, to: Self.notch, Self.notchFrame,
                     on: Self.builtIn, drawn: drawn)
                == .morph(AnchorMorph(from: CGRect(x: 292, y: 232, width: 40, height: 26))))
    }

    /// The other way, the notch was flush with the top of the display and
    /// the pill's window hangs 2pt lower: the notch's top 2pt are above the
    /// window, which would cut them off on the first frame. It fades out and
    /// back in where it is instead.
    @Test func theNotchBecomingAPillOnItsOwnDisplayFadesOnTheSpot() {
        let drawn = PanelMove.Drawn(before: Self.closedNotch, after: Self.closedPill, display: Self.builtIn)
        #expect(move(Self.notch, Self.notchFrame, to: Self.builtInPill, Self.builtInPillFrame,
                     on: Self.builtInBelowNotch, drawn: drawn)
                == .fadeInPlace(.onTheSpot))
    }

    /// The menu bar shown again: the pill goes up 6pt into it and 6pt
    /// shorter, and where it hung is inside the new window. It morphs.
    @Test func thePillGoingUpIntoTheMenuBarMorphs() {
        let drawn = PanelMove.Drawn(before: Self.closedBelowBar, after: Self.closedPill, display: Self.landscape)
        #expect(move(Self.belowBar, Self.belowBarFrame, to: Self.inBar, Self.inBarFrame,
                     on: Self.landscape, drawn: drawn)
                == .morph(AnchorMorph(from: CGRect(x: 290, y: 222, width: 40, height: 32))))
    }

    /// The menu bar hidden: the window comes down 6pt with the pill, and the
    /// pill as it was would start above it. A fade on the spot.
    @Test func thePillComingDownOutOfTheMenuBarFadesOnTheSpot() {
        let drawn = PanelMove.Drawn(before: Self.closedPill, after: Self.closedBelowBar, display: Self.landscape)
        #expect(move(Self.inBar, Self.inBarFrame, to: Self.belowBar, Self.belowBarFrame,
                     on: Self.landscape, drawn: drawn)
                == .fadeInPlace(.onTheSpot))
    }

    /// The built-in in a mode with more space: a notch of another size on
    /// the same display. The hardware does not move, and the drawing has to
    /// stay on it, so it is placed at once, whatever a morph could hold.
    @Test func aNotchOfAnotherSizeIsPlacedAtOnce() {
        let moreSpace = CGRect(x: 0, y: 0, width: 1800, height: 1169)
        let wider = Anchor.notch(CGRect(x: 800, y: 1137, width: 200, height: 32))
        let widerFrame = CGRect(x: 590, y: 909, width: 620, height: 260)
        let drawn = PanelMove.Drawn(
            before: Self.closedNotch, after: CGRect(x: 210, y: 228, width: 200, height: 32), display: Self.builtIn
        )
        #expect(move(Self.notch, Self.notchFrame, to: wider, widerFrame, on: moreSpace, drawn: drawn) == .inPlace)
    }

    /// The open panel is the whole window, and a window that moves at all
    /// cannot hold the old one: it fades.
    @Test func theOpenPanelChangingAnchorFadesOnTheSpot() {
        let whole = CGRect(x: 0, y: 0, width: 620, height: 260)
        let drawn = PanelMove.Drawn(before: whole, after: whole, display: Self.builtInBelowNotch)
        #expect(move(Self.builtInPill, Self.builtInPillFrame, to: Self.notch, Self.notchFrame,
                     on: Self.builtIn, drawn: drawn)
                == .fadeInPlace(.onTheSpot))
    }

    /// A new text size or panel width keeps the anchor, and the window grows
    /// around it. Closed, the shape does not move on screen. Open, its
    /// content is laid out at the new size at once, and a slab growing round
    /// text already its new size would show the text spilling out: placed at
    /// once, open or closed.
    @Test func aNewTextSizeWithThePanelOpenIsPlacedAtOnce() {
        let larger = CGRect(x: 212, y: 1760, width: 680, height: 300)
        let drawn = PanelMove.Drawn(
            before: CGRect(x: 0, y: 0, width: 620, height: 260),
            after: CGRect(x: 0, y: 0, width: 680, height: 300),
            display: Self.landscape
        )
        #expect(move(Self.landscapePill, Self.landscapeFrame, to: Self.landscapePill, larger,
                     on: Self.landscape, drawn: drawn)
                == .inPlace)
    }

    /// Keeping clear of the menus with a Wide panel on the portrait display:
    /// the window, 760pt, stops at the right edge after 160pt while the pill
    /// goes on 230pt. Not a slide, but the capsule it showed is still inside
    /// the window, 200pt in: it morphs along the bar to 430pt.
    @Test func aShiftThePanelEdgeStopsPartWayMorphs() {
        let centred = Anchor.pill(CGRect(x: 1962, y: 1961, width: 180, height: 26))
        let centredFrame = CGRect(x: 1672, y: 1727, width: 760, height: 260)
        let farRight = Anchor.pill(CGRect(x: 2192, y: 1961, width: 180, height: 26))
        let clampedFrame = CGRect(x: 1832, y: 1727, width: 760, height: 260)
        let drawn = PanelMove.Drawn(
            before: CGRect(x: 360, y: 234, width: 40, height: 26),
            after: CGRect(x: 430, y: 234, width: 40, height: 26),
            display: Self.portrait
        )
        #expect(move(centred, centredFrame, to: farRight, clampedFrame, on: Self.portrait, drawn: drawn)
                == .morph(AnchorMorph(from: CGRect(x: 200, y: 234, width: 40, height: 26))))
        // Under Reduce Motion it is a keeping-clear move like any other, and
        // placed at once: a fade would blink the pill on every switch.
        #expect(move(centred, centredFrame, to: farRight, clampedFrame, on: Self.portrait,
                     reduceMotion: true, drawn: drawn)
                == .inPlace)
    }

    /// Reduce Motion: a change of the anchor's kind or size fades on the
    /// spot, even where it could morph. Nothing travels.
    @Test func underReduceMotionAChangeOfShapeFadesOnTheSpot() {
        let drawn = PanelMove.Drawn(before: Self.closedBelowBar, after: Self.closedPill, display: Self.landscape)
        #expect(move(Self.belowBar, Self.belowBarFrame, to: Self.inBar, Self.inBarFrame,
                     on: Self.landscape, reduceMotion: true, drawn: drawn)
                == .fadeInPlace(.onTheSpot))
    }

    /// Without being told what is drawn, it is the closed shapes, and the
    /// display has not moved: the notch becoming a pill on a display whose
    /// frame stayed is still the notch above the pill's window.
    @Test func withoutTheShapesItAsksAboutTheClosedOnes() {
        let pill = Anchor.pill(CGRect(x: 666, y: 954, width: 180, height: 26))
        let pillFrame = CGRect(x: 446, y: 720, width: 620, height: 260)
        #expect(move(Self.notch, Self.notchFrame, to: pill, pillFrame, on: Self.builtIn)
                == .fadeInPlace(.onTheSpot))
        #expect(move(pill, pillFrame, to: Self.notch, Self.notchFrame, on: Self.builtIn)
                == .morph(AnchorMorph(from: CGRect(x: 292, y: 232, width: 40, height: 26))))
    }

    // MARK: - The morph itself

    /// It starts exactly where the old shape was and ends exactly on the new
    /// one, and holds there either side of its time.
    @Test func theMorphRunsFromTheOldShapeToTheNew() {
        let from = Self.closedBelowBar.offsetBy(dx: 0, dy: -6)
        let to = Self.closedPill
        #expect(AnchorMorph.rect(from: from, to: to, progress: 0) == from)
        #expect(AnchorMorph.rect(from: from, to: to, progress: 1) == to)
        #expect(AnchorMorph.rect(from: from, to: to, progress: -0.5) == from)
        #expect(AnchorMorph.rect(from: from, to: to, progress: 1.5) == to)
    }

    /// Off at a fair pace and settling gently: past halfway at half time.
    @Test func theMorphEasesOut() {
        let from = CGRect(x: 0, y: 0, width: 40, height: 26)
        let to = CGRect(x: 100, y: 0, width: 40, height: 26)
        let half = AnchorMorph.rect(from: from, to: to, progress: 0.5)
        #expect(half.minX > 70 && half.minX < 100)
    }

    /// Every step of the way covers what the two shapes share, never less:
    /// that is the region it accepts clicks in while it morphs. A curve that
    /// overshot would leave it.
    @Test func everyStepCoversWhatBothShapesShare() {
        let from = CGRect(x: 290, y: 222, width: 40, height: 32)
        let to = CGRect(x: 200, y: 234, width: 185, height: 26)
        let shared = from.intersection(to)
        #expect(!shared.isEmpty)
        for step in 0...40 {
            let rect = AnchorMorph.rect(from: from, to: to, progress: Double(step) / 40)
            #expect(rect.contains(shared), "step \(step): \(rect)")
        }
    }

    /// As long as the other moves: about a quarter of a second.
    @Test func theMorphIsShort() {
        #expect(AnchorMorph.standardDuration >= 0.2)
        #expect(AnchorMorph.standardDuration <= 0.3)
        #expect(AnchorMorph(from: .zero).duration == AnchorMorph.standardDuration)
    }

    /// The fade on the spot: nothing arrives from anywhere, so nothing drops,
    /// and it is as quick as the trip between displays.
    @Test func theFadeOnTheSpotDoesNotTravel() {
        let fade = DisplayHandoff.onTheSpot
        #expect(fade.drop == 0)
        #expect(fade.fadeOut > 0 && fade.fadeIn > 0)
        #expect(fade.fadeOut + fade.fadeIn <= 0.3)
    }

    /// The same fades as a trip under Reduce Motion, on purpose (review of
    /// #81): nothing travels in either, and under Reduce Motion every change
    /// of shape fades on the spot, so the two are what one setting shows for
    /// a move. One retimed alone would make the same system setting fade at
    /// two speeds.
    @Test func theFadeOnTheSpotIsReduceMotionsTrip() {
        #expect(DisplayHandoff.onTheSpot == .reduced)
    }

    // MARK: - What the shape is doing meanwhile (review of #81)

    /// The landscape pill in the menu bar, 6pt into a morph up from below
    /// it, the panel then made wider by a new text size: the same anchor in
    /// a window 60pt wider and 40pt taller. Placed at once, the shape jumped
    /// to the morph's end; it morphs on from where it has got to, carried
    /// into the new window -- 30pt right, 40pt up.
    @Test func aNewTextSizeHalfwayThroughAMorphMorphsOn() {
        let larger = CGRect(x: 212, y: 1760, width: 680, height: 300)
        let halfway = CGRect(x: 290, y: 230, width: 40, height: 28)
        let drawn = PanelMove.Drawn(
            before: halfway, after: CGRect(x: 320, y: 274, width: 40, height: 26),
            display: Self.landscape, isMorphing: true
        )
        #expect(move(Self.inBar, Self.inBarFrame, to: Self.inBar, larger, on: Self.landscape, drawn: drawn)
                == .morph(AnchorMorph(from: CGRect(x: 320, y: 270, width: 40, height: 28))))
        // At rest, the same change is placed at once, as it always was.
        var resting = drawn
        resting.isMorphing = false
        #expect(move(Self.inBar, Self.inBarFrame, to: Self.inBar, larger, on: Self.landscape, drawn: resting)
                == .inPlace)
        // And under Reduce Motion, where nothing morphs to go on with.
        #expect(move(Self.inBar, Self.inBarFrame, to: Self.inBar, larger, on: Self.landscape,
                     reduceMotion: true, drawn: drawn)
                == .inPlace)
    }

    /// The notch becoming another notch halfway through the pill's morph
    /// into it -- the built-in switched mode twice in quick succession: the
    /// hardware stays put, and so does the shape on its way there; it morphs
    /// on from where it is rather than jumping to the end.
    @Test func aNotchOfAnotherSizeHalfwayThroughAMorphMorphsOn() {
        let shifted = Anchor.notch(CGRect(x: 652, y: 952, width: 205, height: 30))
        let shiftedFrame = CGRect(x: 444, y: 722, width: 620, height: 260)
        let halfway = CGRect(x: 250, y: 231, width: 120, height: 28)
        let drawn = PanelMove.Drawn(
            before: halfway, after: CGRect(x: 208, y: 230, width: 205, height: 30),
            display: Self.builtIn, isMorphing: true
        )
        #expect(move(Self.notch, Self.notchFrame, to: shifted, shiftedFrame, on: Self.builtIn, drawn: drawn)
                == .morph(AnchorMorph(from: halfway)))
    }

    /// The menu bar shown again just as the panel peeked: the peek's spring
    /// is still carrying the shape, and `before`, its end, is not where it
    /// is drawn. A morph from there would jump it to its full size on the
    /// first frame; it fades on the spot instead, as a change it cannot
    /// morph does.
    @Test func whileASpringCarriesTheShapeItFadesOnTheSpot() {
        var drawn = PanelMove.Drawn(before: Self.closedBelowBar, after: Self.closedPill, display: Self.landscape)
        drawn.isSpringing = true
        #expect(move(Self.belowBar, Self.belowBarFrame, to: Self.inBar, Self.inBarFrame,
                     on: Self.landscape, drawn: drawn)
                == .fadeInPlace(.onTheSpot))
    }
}
