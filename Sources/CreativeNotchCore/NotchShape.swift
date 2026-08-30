import CoreGraphics

/// The visible region of the panel, in panel-local coordinates.
///
/// The window is always the full expanded size, so everything outside this
/// rect must pass clicks through to whatever is underneath — otherwise the
/// panel eats menu bar clicks across a 620pt band.
public enum NotchShape {

    /// How much of the panel is currently drawn. Deliberately coarser than
    /// `NotchState`: `.receiving` and `.open` are both `.expanded` here.
    public enum Presentation: Equatable, Sendable {
        case closed
        case peek
        case expanded
    }

    /// The four corner radii the panel is drawn with.
    public struct CornerRadii: Equatable, Sendable {
        public var topLeading: CGFloat
        public var bottomLeading: CGFloat
        public var bottomTrailing: CGFloat
        public var topTrailing: CGFloat

        public init(
            topLeading: CGFloat,
            bottomLeading: CGFloat,
            bottomTrailing: CGFloat,
            topTrailing: CGFloat
        ) {
            self.topLeading = topLeading
            self.bottomLeading = bottomLeading
            self.bottomTrailing = bottomTrailing
            self.topTrailing = topTrailing
        }
    }

    /// How the panel's corners are rounded.
    ///
    /// Lives beside `visibleRect` because the panel's shape and its
    /// rounding are one decision: a rect that hugs the notch and a radius
    /// that ignores it produce exactly the artefact this fixes.
    public static func cornerRadii(presentation: Presentation, anchor: Anchor) -> CornerRadii {
        guard anchor.isNotch else {
            // A pill floats below the menu bar with nothing to merge into.
            let r = NotchGeometry.panelCornerRadius
            return CornerRadii(topLeading: r, bottomLeading: r, bottomTrailing: r, topTrailing: r)
        }

        // Anything on a notch is flush with the screen's top edge, so its
        // top corners never round — that would leave wedges of desktop
        // showing above the panel.
        let bottom = presentation == .closed
            ? NotchGeometry.notchCornerRadius   // match the hardware cutout
            : NotchGeometry.panelCornerRadius   // now it is a panel, not the notch
        return CornerRadii(
            topLeading: 0,
            bottomLeading: bottom,
            bottomTrailing: bottom,
            topTrailing: 0
        )
    }

    /// Whether the ambient now-playing badge is showing.
    ///
    /// The one place that question is answered. The drawn shape, the
    /// hit-test region and the hover tracking rect all have to agree about
    /// whether the badge is there, and a second spelling of
    /// `isPlaying == true` somewhere else is the same "two derivations of
    /// one thing" that produced this project's only Critical bug.
    ///
    /// Paused media is not playing media: the badge answers "is something
    /// playing", so a badge over a paused track would be a lie.
    public static func showsBadge(nowPlaying: TrackSnapshot?) -> Bool {
        nowPlaying?.isPlaying == true
    }

    /// Panel-local, bottom-left origin, y increasing upward — matching an
    /// unflipped `NSView`.
    ///
    /// `badge` is defaulted so the three consumers that must agree — the
    /// drawn rect, the hit test and the hover tracking rect — all widen
    /// from this one function rather than each adding the badge's width
    /// themselves.
    public static func visibleRect(
        presentation: Presentation,
        anchor: Anchor,
        panelFrame: CGRect,
        badge: Bool = false
    ) -> CGRect {
        let local = CGRect(
            x: anchor.rect.minX - panelFrame.minX,
            y: anchor.rect.minY - panelFrame.minY,
            width: anchor.rect.width,
            height: anchor.rect.height
        )

        switch presentation {
        case .closed:
            // A closed notch's rect *is* the camera housing, so the badge
            // cannot live inside it — it grows into the right ear, which
            // is menu bar. Trailing side only: status items cluster at the
            // far right, so the space immediately beside the notch is
            // nearly always empty, and the left ear holds the app menus.
            //
            // A pill is not grown. There is no camera housing to avoid —
            // the pill is drawn black and its closed rect shows nothing at
            // all today, so the badge simply renders inside it. Growing it
            // would put an asymmetric stub on a floating rounded widget
            // for no reason, exactly as `.peek` leaves the pill's centred
            // slab alone.
            guard badge, anchor.isNotch else { return local }
            return CGRect(
                x: local.minX,
                y: local.minY,
                width: local.width + NotchGeometry.nowPlayingBadgeWidth,
                height: local.height
            )

        case .peek:
            // On real hardware the peek grows sideways into the ears and
            // keeps the notch's own height, so the icon and the bar land
            // beside the camera housing instead of behind it. A centred
            // slab put 72% of the level bar under the notch on a 14" Mac.
            if anchor.isNotch {
                let ear = NotchGeometry.peekEarWidth
                return CGRect(
                    x: local.minX - ear,
                    y: local.minY,
                    width: local.width + ear * 2,
                    height: local.height
                )
            }
            // A notchless Mac has nothing to avoid, so the pill keeps the
            // original centred slab.
            let size = NotchGeometry.peekSize
            return CGRect(
                x: local.midX - size.width / 2,
                y: local.maxY - size.height,
                width: size.width,
                height: size.height
            )

        case .expanded:
            return CGRect(origin: .zero, size: panelFrame.size)
        }
    }

}
