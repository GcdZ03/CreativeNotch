import CoreGraphics

/// How the panel gets from the geometry it shows to a new one (2026-10-28).
///
/// Following focus takes the notch between displays many times an hour, and
/// it used to vanish from one and appear on the other in the same frame:
/// measured on a three-display desk, one step of the window's bounds and
/// alpha at 1 throughout, which read as a glitch rather than a decision.
/// Between displays it now fades out where it was and fades in where it is
/// going (`DisplayHandoff`). A move on the display it is on -- keeping clear
/// of the menus, a new text size, the display changing mode -- is no trip
/// anywhere, and is not dressed up as one.
///
/// Except that the pill keeping clear of the menus snapped sideways on
/// every switch between apps with long and short menus, and a jump along
/// the bar reads as a glitch as much as one between displays. When a move
/// on the same display is only that -- the same picture further along the
/// bar -- it slides there (`PanelSlide`).
///
/// And the anchor itself changing on the display it is on snapped too: the
/// notch becoming a pill when the built-in changes to a mode without the
/// notch's band, or back; the pill going between the menu bar and below it
/// when the menu bar is hidden or shown; the pill keeping clear of the
/// menus where the display's edge stops its window. Those now morph, the
/// drawn shape going from where it was to where it is going inside the
/// window (`AnchorMorph`), or, where the window cannot show where it was,
/// fade out and back in on the spot (2026-10-28).
public enum PanelMove: Equatable, Sendable {
    /// The same geometry: nothing moves.
    case stay
    /// The same display: placed at once.
    case inPlace
    /// The same display, the same pill further along the bar: slid there.
    case slide(PanelSlide)
    /// The same display, another anchor, and the new window holds where the
    /// shape was: it morphs from there.
    case morph(AnchorMorph)
    /// The same display, another anchor the window cannot morph to: faded
    /// out and back in where it is, by the same steps as a trip.
    case fadeInPlace(DisplayHandoff)
    /// Another display: faded across.
    case betweenDisplays(DisplayHandoff)

    /// The shape on screen either side of a move, which decides whether a
    /// change of anchor can morph (2026-10-28). Rectangles are panel-local,
    /// bottom-left origin, as `NotchShape.visibleRect` gives them.
    public struct Drawn: Equatable, Sendable {
        /// The shape as drawn now -- part way through a morph, where it has
        /// got to -- in the window where it stands.
        public var before: CGRect
        /// The shape as it will be drawn, in the window it is going to.
        public var after: CGRect
        /// The frame of the display `before` was placed on. A mode change
        /// moves the display's top under the shape, and where the shape was
        /// is where it was *on its display*.
        public var display: CGRect
        /// Whether `before` is part way through a morph (2026-10-28, review
        /// of #81). A new window around the same anchor -- a text size
        /// changed halfway -- then morphs on from there rather than placing
        /// the shape at its end at once.
        public var isMorphing: Bool
        /// Whether a state's spring is still carrying the shape (2026-10-28,
        /// review of #81). `before` is then where that spring is going, not
        /// where it has got to, and a morph from it would jump the shape
        /// there on its first frame: it fades on the spot instead.
        public var isSpringing: Bool

        public init(
            before: CGRect, after: CGRect, display: CGRect,
            isMorphing: Bool = false, isSpringing: Bool = false
        ) {
            self.before = before
            self.after = after
            self.display = display
            self.isMorphing = isMorphing
            self.isSpringing = isSpringing
        }
    }

    /// The move from the anchor and frame shown now to the ones asked for on
    /// `screen`, the destination display's frame.
    ///
    /// "The same display" is decided by where the panel *is*: the
    /// destination's frame overlaps the window as it stands. The window hangs
    /// from the top of its display and is never wider than it, so it overlaps
    /// that display and no other.
    ///
    /// Not by comparing the metrics that asked: a display changing mode has
    /// new metrics and is still the display the pill is on. Nor by the
    /// anchor's centre, which was the first rule: measured with a 1920-wide
    /// display stacked above the built-in one switching to 1680x1050, macOS
    /// kept its bottom edge against the built-in and brought its top down
    /// 30pt, so the pill's old centre was above the display it was still on.
    /// And an overlap, not a shared edge: the built-in's panel ends exactly
    /// where the display stacked above it begins.
    ///
    /// `drawn` is what is on screen either side. Left out, it is the closed
    /// shapes with nothing in them, on a display that has not moved.
    public static func from(
        _ shown: Anchor, frame shownFrame: CGRect,
        to anchor: Anchor, frame: CGRect,
        on screen: CGRect,
        reduceMotion: Bool,
        drawn: Drawn? = nil
    ) -> PanelMove {
        if shown == anchor && shownFrame == frame { return .stay }
        guard screen.intersects(shownFrame) else {
            return .betweenDisplays(reduceMotion ? .reduced : .standard)
        }
        if isAlongTheBar(shown, frame: shownFrame, to: anchor, frame: frame) {
            return reduceMotion ? .inPlace : .slide(.standard)
        }
        return reshaping(
            shown, frame: shownFrame, to: anchor, frame: frame, on: screen,
            reduceMotion: reduceMotion,
            drawn: drawn ?? .closed(shown, frame: shownFrame, to: anchor, frame: frame, on: screen)
        )
    }

    /// A move on the display the panel is on that is not a slide
    /// (2026-10-28).
    ///
    /// Placed at once when the anchor is the same -- a new text size, panel
    /// width or tab count grows the window around it, so the closed shape
    /// does not move on screen, and the open panel's content is laid out at
    /// its new size at once, which a slab growing around it would show
    /// spilling out -- and when both are a notch: the hardware does not
    /// move, and the drawing has to stay on it.
    ///
    /// Otherwise the shape morphs from where it was on its display, carried
    /// into the new window (`carried`), if the window holds it. A shape the
    /// window would cut -- the notch flush with the top of a display whose
    /// pill hangs 2pt lower, the open panel in a window that moved -- would
    /// change on the first frame, which is the snap this is for; it fades on
    /// the spot instead. Where the old shape is where the new one is drawn,
    /// nothing on screen moved, and it is placed at once.
    ///
    /// Under Reduce Motion nothing travels: a change of shape fades on the
    /// spot, and the same pill keeping clear of the menus is placed at once,
    /// as when it slides, since a fade would blink it on every switch.
    ///
    /// Two things the shape may be doing meanwhile (2026-10-28, review of
    /// #81). Part way through a morph, a new window around the same anchor
    /// morphs on from where the shape has got to, carried into it as any
    /// morph's start is: placed at once, it jumped to the morph's end. And
    /// while a state's spring carries the shape, where it is drawn is
    /// nowhere `before` can say, so it cannot morph from there; it fades on
    /// the spot, and the window moves while nothing is drawn in it.
    static func reshaping(
        _ shown: Anchor, frame shownFrame: CGRect,
        to anchor: Anchor, frame: CGRect,
        on screen: CGRect,
        reduceMotion: Bool,
        drawn: Drawn
    ) -> PanelMove {
        let sameShape = shown == anchor || (shown.isNotch && anchor.isNotch)
        if sameShape && !drawn.isMorphing { return .inPlace }
        let from = carried(drawn.before, from: shownFrame, on: drawn.display, into: frame, on: screen)
        if from == drawn.after { return .inPlace }
        let holds = CGRect(origin: .zero, size: frame.size).contains(from)
        if sameShape { return holds && !reduceMotion ? .morph(AnchorMorph(from: from)) : .inPlace }
        if reduceMotion {
            let samePill = !shown.isNotch && !anchor.isNotch && shown.rect.size == anchor.rect.size
            return samePill ? .inPlace : .fadeInPlace(.onTheSpot)
        }
        guard holds, !drawn.isSpringing else { return .fadeInPlace(.onTheSpot) }
        return .morph(AnchorMorph(from: from))
    }

    /// `rect`, drawn in the window at `shownFrame` on a display at `display`,
    /// in the window at `frame` on the same display, now at `screen`: at the
    /// same place on the display, measured from its top centre.
    ///
    /// The top centre because that is what the notch and the pill hang from:
    /// a mode change that narrows a display and brings its top down leaves a
    /// centred pill at the top centre still, and nothing on screen moved.
    /// On a display that did not change, it is the same place on screen.
    static func carried(
        _ rect: CGRect, from shownFrame: CGRect, on display: CGRect,
        into frame: CGRect, on screen: CGRect
    ) -> CGRect {
        rect.offsetBy(
            dx: shownFrame.minX + (screen.midX - display.midX) - frame.minX,
            dy: shownFrame.minY + (screen.maxY - display.maxY) - frame.minY
        )
    }

    /// Whether the new geometry is the one shown, moved sideways and nothing
    /// else (2026-10-28): a pill both times, of one size, in a window of one
    /// size at one height, and at the same place inside it. Then moving the
    /// window alone takes the drawing exactly to where it ends up, and the
    /// window's content is not laid out again for any step of the way.
    ///
    /// A pill only: a real notch's rectangle moves only when its display
    /// changes mode, and a drawn notch sliding would leave the camera it
    /// covers. At the same place in the window: near the display's right
    /// edge the frame stops while the pill goes on (`NotchGeometry.panelFrame`
    /// keeps it on screen), and that is placed at once.
    static func isAlongTheBar(_ shown: Anchor, frame shownFrame: CGRect, to anchor: Anchor, frame: CGRect) -> Bool {
        guard !shown.isNotch, !anchor.isNotch,
              shown.rect.size == anchor.rect.size,
              shownFrame.size == frame.size,
              shownFrame.minY == frame.minY
        else { return false }
        // Up and down it is the same place already: `panelFrame` hangs the
        // window from the pill's top, and both keep their heights and tops.
        return shown.rect.minX - shownFrame.minX == anchor.rect.minX - frame.minX
    }
}

/// The trip between two displays: a fade out on the one it leaves, then a
/// fade in on the one it arrives at, the shape dropping `drop` points from the
/// top edge as it does (2026-10-28).
///
/// One-shot and short. The fade out is the quicker half, so the notch leaves
/// as soon as focus does; the fade in carries the arrival, which is the part
/// the eye goes to. Both are the window's own alpha, so nothing is redrawn
/// for them.
public struct DisplayHandoff: Equatable, Sendable {
    /// Seconds to fade out on the display it leaves.
    public var fadeOut: Double
    /// Seconds to fade in on the display it arrives at.
    public var fadeIn: Double
    /// How far above its place the shape starts as it fades in, in points.
    /// The window's top edge clips it, so it comes down out of the top of
    /// the screen rather than crossing the menu bar.
    public var drop: CGFloat

    public init(fadeOut: Double, fadeIn: Double, drop: CGFloat) {
        self.fadeOut = fadeOut
        self.fadeIn = fadeIn
        self.drop = drop
    }

    /// 0.26s in all: long enough to read as a move, short enough that the
    /// notch is on the new display before the eye has followed focus there.
    public static let standard = DisplayHandoff(fadeOut: 0.08, fadeIn: 0.18, drop: 6)

    /// Reduce Motion: the same short fades, and nothing travels.
    public static let reduced = DisplayHandoff(fadeOut: 0.08, fadeIn: 0.15, drop: 0)

    /// Out and back in on the display it is on, when the anchor changes and
    /// the window cannot morph it (2026-10-28). No drop: it arrives from
    /// nowhere. Reduce Motion asks nothing less of it, since nothing in it
    /// travels.
    public static let onTheSpot = DisplayHandoff(fadeOut: 0.08, fadeIn: 0.15, drop: 0)
}

extension PanelMove.Drawn {
    /// The closed shapes with nothing in them, the display where it is.
    static func closed(_ shown: Anchor, frame shownFrame: CGRect, to anchor: Anchor, frame: CGRect, on screen: CGRect) -> Self {
        Self(
            before: NotchShape.visibleRect(presentation: .closed, anchor: shown, panelFrame: shownFrame),
            after: NotchShape.visibleRect(presentation: .closed, anchor: anchor, panelFrame: frame),
            display: screen
        )
    }
}

/// The drawn shape going from where it was to the new anchor's shape inside
/// the window, when the anchor changes on its own display (2026-10-28).
///
/// The window is placed at once, as before, and the shape is drawn where the
/// old one was in it -- the same pixels on the first frame as on the last
/// before -- then eased to its new place and size. One-shot, and only while
/// it changes: SwiftUI draws the steps (`NotchRootView`), and nothing runs
/// once it is there.
///
/// Eased out and never past the end: every step of the way then covers
/// what the two shapes share, which is all the panel accepts clicks in
/// meanwhile, so the hit test never runs ahead of the drawing.
public struct AnchorMorph: Equatable, Sendable {
    /// Where it starts, panel-local, bottom-left origin, in the window it
    /// is going to.
    public var from: CGRect
    /// Seconds from there to the new shape.
    public var duration: Double

    public init(from: CGRect, duration: Double = AnchorMorph.standardDuration) {
        self.from = from
        self.duration = duration
    }

    /// A quarter of a second, the slide's: the moves keep one pace.
    public static let standardDuration: Double = 0.25

    /// The shape `progress` of the way through its time, from `from` to
    /// `to`: held at either end outside 0...1.
    ///
    /// Cubic ease-out, quick off the mark and settling without overshoot.
    /// The view steps `progress` evenly and asks here, and so does the app
    /// for where a morph cut short has got to, so the two cannot disagree
    /// about the curve.
    public static func rect(from: CGRect, to: CGRect, progress: Double) -> CGRect {
        if progress <= 0 { return from }
        if progress >= 1 { return to }
        let rest = 1 - progress
        let eased = 1 - rest * rest * rest
        func lerp(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * eased }
        return CGRect(
            x: lerp(from.minX, to.minX),
            y: lerp(from.minY, to.minY),
            width: lerp(from.width, to.width),
            height: lerp(from.height, to.height)
        )
    }
}

/// The pill sliding along its menu bar to its new place (2026-10-28):
/// keeping clear of the menus of the app that came forward, or back to the
/// centre for one whose menus are short.
///
/// One-shot, and only while it moves. The window travels, not its content,
/// so it is the window server that draws each step of the way; see
/// `AnimatedPanelSlider`. Under Reduce Motion there is no slide: the pill is
/// placed at once, as it always was. Not a fade, as between displays: there
/// the notch leaves one display for another, and here it would blink out
/// and back on every switch between two apps, in the one place it already
/// was -- more to look at, for the person who asked for less.
public struct PanelSlide: Equatable, Sendable {
    /// Seconds from where the pill is to where it is going.
    public var duration: Double

    public init(duration: Double) {
        self.duration = duration
    }

    /// A quarter of a second: about as long as the trip between displays, so
    /// the two moves keep one pace, and over before the eye has come back
    /// from the menus it was reading. Measured on screen, a 206pt slide took
    /// a median of 26 steps of the window, one every ~8.5ms.
    public static let standard = PanelSlide(duration: 0.25)
}
