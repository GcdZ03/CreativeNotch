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

    /// How far the music peek hangs below the notch's own band.
    ///
    /// Holds a 48pt cover with 12pt above it — title over artist and a
    /// play/pause button beside it — then the progress bar and its two
    /// times below, with 12pt under those.
    ///
    /// Fixed, whether or not the track publishes a position: a peek whose
    /// height depended on it would need the position threaded into
    /// `visibleRect`, and would resize mid-glance when a reading arrived.
    /// Without one, the player row sits centred in the same space.
    public static let mediaPeekBodyHeight: CGFloat = 100

    /// How far the battery peek hangs below the notch's band: one compact
    /// row of icon, words, bar and percentage (2026-10-17). Trimmed from
    /// 44pt after seeing it on screen: a three-second glance should not
    /// look like a panel.
    public static let statusPeekBodyHeight: CGFloat = 30

    /// How far the battery peek extends past each side of the notch.
    ///
    /// Narrower than `peekEarWidth`: the row only has to hold "Low Power
    /// Mode Off", or a short word plus a small bar and a percentage, so the
    /// full peek width made it look larger than what it says.
    public static let statusPeekEarWidth: CGFloat = 70

    /// How far the ambient now-playing badge extends past the *trailing*
    /// edge of a physical notch: the cover, then the equalizer, together in
    /// the right ear (2026-10-17).
    ///
    /// The closed notch's own rect *is* the camera housing, so a badge drawn
    /// inside it would be invisible — it has to grow into the ears, which are
    /// menu bar. From 2026-10-15 the cover took a 34pt *leading* ear, for the
    /// symmetric look, and on screen it covered the end of app menus ("Help"
    /// cut to "Hel"). So both now share the trailing ear, where the space
    /// beside the notch is nearly always empty, and the left stays clear.
    ///
    /// 68pt is the same menu bar the two 34pt ears took, moved to one side:
    /// 6pt, a cover up to `maxCoverAspect` × 22pt wide (33pt), 5pt, the 18pt
    /// bars, 6pt. A square cover leaves the slack at the far end.
    public static let nowPlayingBadgeWidth: CGFloat = 68

    /// How much wider than tall a cover tile may be. Video thumbnails are
    /// 16:9; cropped to a square they lose most of the picture, and at full
    /// width they would take too much of the menu bar.
    public static let maxCoverAspect: CGFloat = 1.5

    /// A cover tile's width for a given height and artwork aspect ratio:
    /// square for square or tall art, wider for wide art, up to
    /// `maxCoverAspect`. A missing or broken aspect is square.
    public static func coverWidth(height: CGFloat, aspect: CGFloat?) -> CGFloat {
        guard let aspect, aspect.isFinite, aspect > 0 else { return height }
        return height * min(max(aspect, 1), maxCoverAspect)
    }

    /// How far the countdown extends past the trailing edge of a notch.
    ///
    /// Wider than `nowPlayingBadgeWidth` because it holds text rather than
    /// a square cover: `TimerDisplay.widestText` is `"0:00"` at 12pt
    /// rounded, which needs roughly 32pt, plus 6pt either side.
    ///
    /// Fixed, not fitted to the current string. A width that tracked the
    /// text would resize the closed notch every time a digit dropped —
    /// visually jittery, and worse, it would re-run the drawn/hit-test/
    /// hover sync on every change, turning a once-a-minute redraw into a
    /// once-a-minute geometry update.
    public static let timerBadgeWidth: CGFloat = 44

    /// How far a recording indicator extends past the trailing edge.
    ///
    /// Narrower than the timer's, because it holds a dot rather than text.
    /// It deliberately does NOT show elapsed time: a duration would need the
    /// same once-a-second redraw the timer's badge was carefully designed to
    /// avoid, and what this badge has to communicate is "the camera is on",
    /// which a dot says completely.
    public static let recordingBadgeWidth: CGFloat = 28

    /// How far the capture indicator extends past the trailing edge.
    ///
    /// Wide enough for two glyphs side by side, because the microphone and the
    /// camera can be in use at once and collapsing that to one icon would hide
    /// half of what the user most wants to know. Fixed at the two-glyph width
    /// whichever is showing: a badge that grew when the second device started
    /// would resize the closed notch mid-call.
    public static let captureBadgeWidth: CGFloat = 40

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
    ///
    /// 20 rather than the closed notch's 12: once it is a panel it reads as
    /// an island, and the reference apps sit between 14 and 24. Also the
    /// peek's radius, since a peek is a panel in miniature.
    public static let panelCornerRadius: CGFloat = 20
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
    ///
    /// `textScale` is `TextSize.scale` (2026-10-24): larger text needs a
    /// larger panel, so both sides grow by the factor the fonts do, through
    /// the same `NotchType.length`. The growth is clamped to the screen, but
    /// never below `expandedSize` -- that is what the panel has always been,
    /// whatever the screen, and the clamp below keeps it on screen as before.
    public static func panelFrame(
        for anchor: Anchor, in m: ScreenMetrics, textScale: CGFloat = 1
    ) -> CGRect {
        let grown = CGSize(
            width: min(NotchType.length(expandedSize.width, scale: textScale), m.frame.width),
            height: min(NotchType.length(expandedSize.height, scale: textScale), m.frame.height)
        )
        let width = max(expandedSize.width, grown.width, anchor.rect.width)
        let height = max(expandedSize.height, grown.height)
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
