import CoreGraphics

/// The open panel's type scale: one function for a font's size and one for
/// a length that holds text, both from a nominal value and `TextSize.scale`
/// (2026-10-24).
///
/// One place, for the reason `PanelLayout` is one place: if each view
/// multiplied its own sizes, one would round differently, or forget, and the
/// panel would clip at the size nobody happened to look at. Every
/// `.notchFont` in the UI target comes through `size`, and the column, tile
/// and row lengths that must grow with their text come through `length`.
///
/// Pure and in Core so the arithmetic -- identity at the default, the grid
/// it snaps to, what a broken factor does -- is tested without a renderer.
///
/// **Not for the closed notch.** Its badges sit in the hardware notch's own
/// band, 32-38pt tall, beside menu bar items; a 12pt countdown scaled by 1.3
/// would overhang the band, and the badge widths are fixed so the closed
/// notch never resizes as digits change (`NotchGeometry.timerBadgeWidth`).
/// The peeks keep their fixed heights for the same reason: they are sized
/// into `visibleRect`, and a peek that grew with a setting would need the
/// setting threaded through the hit test. Both keep plain
/// `.system(size:)` fonts, so neither can pick the scale up by accident.
public enum NotchType {

    /// A font's point size: `nominal` × `scale`, to the nearest half point.
    ///
    /// Half points rather than whole ones because 1.15 × 13 is 14.95 and
    /// whole points would turn adjacent sizes into the same size; half
    /// points are still on the grid of a 2× display. At a scale of one the
    /// result is `nominal` exactly, so the default look is untouched.
    public static func size(_ nominal: CGFloat, scale: CGFloat) -> CGFloat {
        guard let scale = usable(scale) else { return nominal }
        return (nominal * scale * 2).rounded() / 2
    }

    /// A length that has to grow with its text -- a column, a tile, a row's
    /// minimum height -- to the nearest whole point, so a frame does not
    /// land between pixels.
    public static func length(_ nominal: CGFloat, scale: CGFloat) -> CGFloat {
        guard let scale = usable(scale) else { return nominal }
        return (nominal * scale).rounded()
    }

    /// The scale only ever grows the panel. Below one, or not a number at
    /// all, it is no scale: a zero-point font is not a smaller panel, it is
    /// an empty one.
    private static func usable(_ scale: CGFloat) -> CGFloat? {
        guard scale.isFinite, scale > 1 else { return nil }
        return scale
    }
}
