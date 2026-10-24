import CoreGraphics

/// How the open panel is split up: a header as tall as the anchor, whose
/// middle is the camera housing on a notched Mac, and a body that is a
/// fixed media column beside the module pane.
///
/// One function, because the header's three columns and the peek's
/// `notchGap` are the same fact about the same hardware. Every view reads
/// its widths from here rather than deriving them, for the reason
/// ARCHITECTURE.md gives for `visibleRect`: two derivations of one number
/// drift, and this project's only Critical bug was exactly that.
///
/// Nothing here changes the drawn rect, the hit-test rect or the hover
/// rect. The whole layout happens *inside* the expanded rectangle the panel
/// already claims, in the band the content was already padded past.
public struct PanelLayout: Equatable, Sendable {

    /// The width of the music column while media controls are on.
    ///
    /// Fixed whether or not a track is playing, so the pane beside it never
    /// reflows under the user when one starts. A column that appeared with
    /// the first track is what made the camera tab special-case the media
    /// bar; a constant width is what lets it stop.
    public static let mediaColumnWidth: CGFloat = 212

    /// A header icon button's width: a tab, or the gear
    /// (`NotchIconButtonStyle`), grown with the text.
    public static let tabButtonWidth: CGFloat = 34

    /// The gap between two tabs (`PanelTabBar`). Fixed: it is a gap, not
    /// text.
    public static let tabSpacing: CGFloat = 4

    /// How far the header's content sits in from the panel's outer edge, on
    /// either ear (`PanelHeader`).
    public static let earInset: CGFloat = 12

    /// The least room left between the last tab and the camera housing.
    public static let housingClearance: CGFloat = 8

    /// How wide an ear has to be to hold `tabCount` tabs at `scale`: the
    /// inset from the panel's edge, the buttons and the gaps between them,
    /// and a clearance before the housing.
    ///
    /// Here rather than measured from a render, because Compact's width is
    /// decided from it (`NotchGeometry.panelFrame`) before anything is drawn;
    /// `PanelTabBar` and `NotchIconButtonStyle` read the same constants, so
    /// the arithmetic and the drawing cannot drift apart.
    public static func tabEarWidth(tabCount: Int, scale: CGFloat = 1) -> CGFloat {
        let count = CGFloat(max(tabCount, 0))
        let buttons = count * NotchType.length(tabButtonWidth, scale: scale)
        let gaps = max(count - 1, 0) * tabSpacing
        return earInset + buttons + gaps + housingClearance
    }

    /// The anchor's height: the hardware notch on a notched Mac, the pill's
    /// own band on a notchless one.
    public let headerHeight: CGFloat

    /// From the panel's left edge to the camera housing. On a pill, half the
    /// panel.
    public let leadingEarWidth: CGFloat

    /// The camera housing, to leave empty. Zero on a pill.
    public let notchGap: CGFloat

    /// From the camera housing to the panel's right edge. On a pill, the
    /// other half.
    public let trailingEarWidth: CGFloat

    /// `Self.mediaColumnWidth` grown with the text, or zero when the column
    /// is not shown.
    public let mediaColumnWidth: CGFloat

    /// Which ear holds the tabs ("Tabs" in Settings, 2026-10-24). The other
    /// holds the battery and the gear. Only the contents swap: the ears'
    /// widths, and the housing between them, are facts about the hardware.
    public let tabsSide: EarSide

    /// The width of the ear that holds the tabs.
    public var tabsEarWidth: CGFloat {
        tabsSide == .left ? leadingEarWidth : trailingEarWidth
    }

    /// The width of the ear that holds the battery and the gear.
    public var statusEarWidth: CGFloat {
        tabsSide == .left ? trailingEarWidth : leadingEarWidth
    }

    /// `textScale` is `TextSize.scale`. The column holds a title and an
    /// artist at the panel's text size, so it grows with them; the panel
    /// frame it is given has grown by the same factor
    /// (`NotchGeometry.panelFrame(for:in:textScale:)`), so the pane beside it
    /// grows too. The header does not: it is the hardware notch's band.
    ///
    /// `tabsSide` names the ear the tabs go in; the default is the left, the
    /// header from before the setting.
    public static func resolve(
        anchor: Anchor, panelFrame: CGRect, showsMedia: Bool, textScale: CGFloat = 1,
        tabsSide: EarSide = .default
    ) -> PanelLayout {
        let header = anchor.rect.height
        let media = showsMedia ? NotchType.length(Self.mediaColumnWidth, scale: textScale) : 0
        guard anchor.isNotch else {
            let half = panelFrame.width / 2
            return PanelLayout(
                headerHeight: header,
                leadingEarWidth: half,
                notchGap: 0,
                trailingEarWidth: panelFrame.width - half,
                mediaColumnWidth: media,
                tabsSide: tabsSide
            )
        }
        // Measured from the *real* notch, not the panel's centre: a panel
        // clamped to a screen edge is off-centre, and a gap drawn in its
        // middle would put the header behind the camera.
        let leading = anchor.rect.minX - panelFrame.minX
        let gap = anchor.rect.width
        return PanelLayout(
            headerHeight: header,
            leadingEarWidth: leading,
            notchGap: gap,
            trailingEarWidth: panelFrame.width - leading - gap,
            mediaColumnWidth: media,
            tabsSide: tabsSide
        )
    }
}
