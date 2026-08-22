import CoreGraphics

public enum NotchGeometry {
    public static let pillSize = CGSize(width: 180, height: 32)
    public static let pillTopGap: CGFloat = 8
    public static let peekSize = CGSize(width: 320, height: 44)
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
        let x = min(max(unclampedX, m.frame.minX), m.frame.maxX - width)
        return CGRect(x: x, y: anchor.rect.maxY - height, width: width, height: height)
    }
}
