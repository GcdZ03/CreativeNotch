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
public enum PanelMove: Equatable, Sendable {
    /// The same geometry: nothing moves.
    case stay
    /// The same display: placed at once.
    case inPlace
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
        if screen.intersects(shownFrame) { return .inPlace }
        return .betweenDisplays(reduceMotion ? .reduced : .standard)
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
