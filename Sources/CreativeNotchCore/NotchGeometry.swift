import CoreGraphics

public enum NotchGeometry {
    public static let pillSize = CGSize(width: 180, height: 32)
    public static let pillTopGap: CGFloat = 8
    public static let peekSize = CGSize(width: 320, height: 44)

    /// How far the peek extends past each side of a physical notch.
    ///
    /// The peek used to be a slab centred on the notch, which drew the
    /// icon and the level bar straight into the camera housing — on a 14"
    /// MacBook, 72% of the bar was invisible. Content now lives in these
    /// ears, so the notch itself is left alone. 110pt holds an 18pt icon
    /// or a readable bar without crowding the menu bar items either side.
    public static let peekEarWidth: CGFloat = 110

    /// Approximates the radius of the hardware notch's bottom corners.
    ///
    /// The closed panel covers the notch's bounding box, but the cutout
    /// itself is rounded — so square corners paint black over real display
    /// pixels either side of the curve, and the panel shows as a
    /// hard-edged rectangle instead of vanishing into the housing.
    ///
    /// macOS exposes no notch corner radius, so this is measured by eye
    /// and deliberately errs large: too small leaves black corners
    /// showing, while too large only reveals desktop pixels the panel was
    /// never meant to cover in the first place.
    public static let notchCornerRadius: CGFloat = 12

    /// The panel's own corner styling, once it is large enough to read as
    /// a panel rather than as the notch.
    public static let panelCornerRadius: CGFloat = 14
    public static let expandedSize = CGSize(width: 620, height: 260)

    /// Resolves the anchor for a screen. Real notch when the hardware has
    /// one, a synthesised pill otherwise.
    public static func anchor(for m: ScreenMetrics) -> Anchor {
        let auxWidth = m.auxiliaryTopLeftWidth + m.auxiliaryTopRightWidth
        if m.safeAreaTopInset > 0, auxWidth > 0, auxWidth < m.frame.width {
            return .notch(CGRect(
                x: m.frame.minX + m.auxiliaryTopLeftWidth,
                y: m.frame.maxY - m.safeAreaTopInset,
                width: m.frame.width - auxWidth,
                height: m.safeAreaTopInset
            ))
        }
        return .pill(CGRect(
            x: m.frame.midX - pillSize.width / 2,
            y: m.frame.maxY - m.menuBarHeight - pillTopGap - pillSize.height,
            width: pillSize.width,
            height: pillSize.height
        ))
    }

    /// The window frame. Always the fully-expanded size so the window never
    /// resizes — content animates inside it instead, which avoids resize
    /// jank. The cost is a large transparent rect, which `NotchShape`
    /// handles via hit-testing.
    public static func panelFrame(for anchor: Anchor, in m: ScreenMetrics) -> CGRect {
        let width = max(expandedSize.width, anchor.rect.width)
        let height = expandedSize.height
        let unclampedX = anchor.rect.midX - width / 2
        // The right bound can fall left of the left bound on a screen
        // narrower than the panel, in which case the left bound wins --
        // otherwise clamping pushes the panel off the near edge while
        // trying to keep it on the far one. No real Mac display is under
        // 620pt, but the invariant should not depend on that.
        let rightBound = max(m.frame.minX, m.frame.maxX - width)
        let x = min(max(unclampedX, m.frame.minX), rightBound)
        return CGRect(x: x, y: anchor.rect.maxY - height, width: width, height: height)
    }
}
