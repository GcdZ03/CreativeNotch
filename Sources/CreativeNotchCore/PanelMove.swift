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
public enum PanelMove: Equatable, Sendable {
    /// The same geometry: nothing moves.
    case stay
    /// The same display: placed at once.
    case inPlace
    /// The same display, the same pill further along the bar: slid there.
    case slide(PanelSlide)
    /// Another display: faded across.
    case betweenDisplays(DisplayHandoff)

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
    public static func from(
        _ shown: Anchor, frame shownFrame: CGRect,
        to anchor: Anchor, frame: CGRect,
        on screen: CGRect,
        reduceMotion: Bool
    ) -> PanelMove {
        if shown == anchor && shownFrame == frame { return .stay }
        if screen.intersects(shownFrame) {
            let along = isAlongTheBar(shown, frame: shownFrame, to: anchor, frame: frame)
            return along && !reduceMotion ? .slide(.standard) : .inPlace
        }
        return .betweenDisplays(reduceMotion ? .reduced : .standard)
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
