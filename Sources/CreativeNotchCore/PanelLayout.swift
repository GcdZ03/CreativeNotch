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

    /// `Self.mediaColumnWidth`, or zero when the column is not shown.
    public let mediaColumnWidth: CGFloat

    public static func resolve(anchor: Anchor, panelFrame: CGRect, showsMedia: Bool) -> PanelLayout {
        let header = anchor.rect.height
        let media = showsMedia ? Self.mediaColumnWidth : 0
        guard anchor.isNotch else {
            let half = panelFrame.width / 2
            return PanelLayout(
                headerHeight: header,
                leadingEarWidth: half,
                notchGap: 0,
                trailingEarWidth: panelFrame.width - half,
                mediaColumnWidth: media
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
            mediaColumnWidth: media
        )
    }
}
