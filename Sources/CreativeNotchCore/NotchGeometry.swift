import CoreGraphics

public enum NotchGeometry {
    /// The pill's width, and its height where there is no menu bar to sit in.
    public static let pillSize = CGSize(width: 180, height: 32)
    /// The pill's gap below the top edge where there is no menu bar to sit in.
    public static let pillTopGap: CGFloat = 8
    /// How far the pill stands in from the menu bar's top and bottom edges,
    /// so it reads as floating in the bar rather than as a notch hung from
    /// the screen's edge.
    public static let pillMenuBarInset: CGFloat = 2
    /// How wide the closed pill is with nothing to show: a small capsule at
    /// the pill's centre (2026-10-26). The full `pillSize.width`, empty,
    /// covered app menus on a narrow display. A badge widens it to the
    /// badge's own width (`NotchShape.visibleRect`).
    public static let pillIdleWidth: CGFloat = 40
    /// The space "Keep clear of app menus" leaves between the end of the
    /// frontmost app's menus and the closed pill (2026-10-26).
    public static let pillMenuGap: CGFloat = 12
    /// The widest the closed pill gets: the idle capsule, or the widest
    /// badge. Keeping clear of the menus keeps clear for this, so a badge
    /// appearing never grows the pill back over them.
    public static let pillClosedMaxWidth: CGFloat = max(
        pillIdleWidth, nowPlayingBadgeWidth, timerBadgeWidth,
        recordingBadgeWidth, captureBadgeWidth, downloadsBadgeWidth
    )
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

    /// One line of lyrics (spec 2026-10-29): the strip under the closed
    /// notch, and the row it adds to the music peek. Below the 33pt menu
    /// bar it covers the top of a title bar or a browser's tab strip, so it
    /// is one line and no more.
    public static let lyricsLineHeight: CGFloat = 22

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

    /// How far the downloads badge extends past the trailing edge.
    ///
    /// A 14pt progress ring and, with more than one download, a count up to
    /// "9+" beside it — 6pt, the ring, 3pt, the count, 8pt. The timer's width,
    /// and fixed for the timer's reason: a slot that grew when a second
    /// download started would re-run the drawn/hit-test/hover sync for a
    /// change nobody asked for.
    public static let downloadsBadgeWidth: CGFloat = 44

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
    ///
    /// The pill sits inside the menu bar, centred, inset from both its edges
    /// (2026-10-26). It used to hang `pillTopGap` below the menu bar, where
    /// a maximised window's top is: on an external display it covered a
    /// browser's tab strip, in every app, all the time. The menu bar is the
    /// one band at the top that no window reaches. With no menu bar measured
    /// -- auto-hidden -- there is no such band, and the pill keeps its old
    /// size and place below the top edge.
    ///
    /// `menusEnd` is how far from the display's left edge the frontmost
    /// app's menus reach (`AppMenus.end`), or 0 to centre the pill as
    /// always -- see `pillCentreX`. A real notch never moves.
    public static func anchor(for m: ScreenMetrics, menusEnd: CGFloat = 0) -> Anchor {
        let auxWidth = m.auxiliaryTopLeftWidth + m.auxiliaryTopRightWidth
        if m.safeAreaTopInset > 0, auxWidth > 0, auxWidth < m.frame.width {
            return .notch(CGRect(
                x: m.frame.minX + m.auxiliaryTopLeftWidth,
                y: m.frame.maxY - m.safeAreaTopInset,
                width: m.frame.width - auxWidth,
                height: m.safeAreaTopInset
            ))
        }
        let centreX = pillCentreX(in: m.frame, menusEnd: menusEnd)
        let inBarHeight = m.menuBarHeight - 2 * pillMenuBarInset
        if inBarHeight > 0 {
            return .pill(CGRect(
                x: centreX - pillSize.width / 2,
                y: m.frame.maxY - pillMenuBarInset - inBarHeight,
                width: pillSize.width,
                height: inBarHeight
            ))
        }
        return .pill(CGRect(
            x: centreX - pillSize.width / 2,
            y: m.frame.maxY - m.menuBarHeight - pillTopGap - pillSize.height,
            width: pillSize.width,
            height: pillSize.height
        ))
    }

    /// Where along the top the pill's centre goes: the display's centre, or,
    /// when the frontmost app's menus reach under the closed pill, just right
    /// of them (2026-10-26).
    ///
    /// On a display with no notch, macOS lays the menus out knowing nothing
    /// of the pill, and on a narrow one a long menu bar ran under it. Moved,
    /// the widest closed shape (`pillClosedMaxWidth`) starts `pillMenuGap`
    /// past the last menu, so neither the idle capsule nor a badge covers
    /// one.
    ///
    /// It goes no further right than leaves room for the open panel centred
    /// on it (`expandedSize`): past that, `panelFrame` would clamp the panel
    /// to the edge and the glances centred on the pill would be cut off.
    /// Menus too long to clear are rare enough that covering the last of
    /// them is the better failure.
    static func pillCentreX(in frame: CGRect, menusEnd: CGFloat) -> CGFloat {
        let clear = frame.minX + menusEnd + pillMenuGap + pillClosedMaxWidth / 2
        let furthest = max(frame.midX, frame.maxX - expandedSize.width / 2)
        return min(max(frame.midX, clear), furthest)
    }

    /// The window frame. Always the fully-expanded size so the window never
    /// resizes — content animates inside it instead, which avoids resize
    /// jank. The cost is a large transparent rect, which `NotchShape`
    /// handles via hit-testing.
    ///
    /// `textScale` is `TextSize.scale` (2026-10-24): larger text needs a
    /// larger panel, so both sides grow by the factor the fonts do, through
    /// the same `NotchType.length`. On a screen too small for that, the
    /// factor comes down to the largest the screen holds
    /// (`fittedTextScale`), both sides together -- never below
    /// `expandedSize` (or Compact's own, narrower width), which is what the
    /// panel has always been, whatever the screen, and the clamp below keeps
    /// it on screen as before.
    ///
    /// `width` is "Panel width" (2026-10-24): it sets the nominal width the
    /// text size then grows (`nominalPanelWidth`), and leaves the height
    /// alone. At `.standard` it is `expandedSize.width`, so the default frame
    /// is the frame from before the setting, exactly. The fit is computed on
    /// that nominal width, not the default's: Wide at Larger on a screen
    /// that holds Default at Larger may come down a step, and Compact may
    /// keep a factor Default could not.
    ///
    /// `tabCount` is how many tabs the header shows (`TabVisibility`): Compact
    /// is sized by it, and Default and Wide only once a sixth tab -- the
    /// calendar -- needs more than they have (`nominalPanelWidth`).
    /// Defaulted to the tabs that ship on (`shippedTabCount`), the header
    /// someone who never switched the calendar on has.
    public static func panelFrame(
        for anchor: Anchor,
        in m: ScreenMetrics,
        textScale: CGFloat = 1,
        width option: PanelWidth = .standard,
        tabCount: Int = shippedTabCount
    ) -> CGRect {
        let nominalWidth = nominalPanelWidth(for: anchor, width: option, tabCount: tabCount)
        let scale = fittedTextScale(textScale, within: m.frame.size, nominalWidth: nominalWidth)
        // The floor is the default width or less: Wide is a preference that
        // a small screen may refuse, but no option makes the panel narrower
        // on a small screen than it has always been there.
        let floor = min(nominalWidth, expandedSize.width)
        let grownWidth = min(NotchType.length(nominalWidth, scale: scale), m.frame.width)
        let width = max(floor, grownWidth, anchor.rect.width)
        let height = max(expandedSize.height, NotchType.length(expandedSize.height, scale: scale))
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

    /// The width `panelFrame` grows with the text for `option`, before the
    /// screen has a say.
    ///
    /// Beside a real notch the housing takes the middle of the header, and
    /// Compact goes no narrower than leaves each ear room for `tabCount` tabs
    /// (`PanelLayout.tabEarWidth`) or for the status items -- dropper,
    /// battery and gear (`PanelLayout.statusEarWidth`) -- whichever is
    /// wider. The ears are equal because the panel is centred on the notch,
    /// and either one may hold either.
    ///
    /// Default and Wide are fixed widths that hold the five tabs that ship
    /// on, on every notch Apple ships, so up to five they never depend on the
    /// count and a module toggle never resizes them. The calendar is a sixth
    /// tab in the same bar (2026-10-24), and six do not fit Default's 215pt
    /// ear on a 14" notch: past five, Default and Wide take the same floor
    /// Compact does, so Default grows to hold them (678pt on a 14" notch)
    /// rather than run the last tab under the camera. Wide already holds
    /// six there and does not move.
    ///
    /// Public so `AppState.textScale` can fit against the same width the
    /// frame was built from.
    public static func nominalPanelWidth(
        for anchor: Anchor, width option: PanelWidth, tabCount: Int = shippedTabCount
    ) -> CGFloat {
        let ears = 2 * max(PanelLayout.tabEarWidth(tabCount: tabCount), PanelLayout.statusEarWidth())
        let floor = (anchor.isNotch ? anchor.rect.width : 0) + ears
        switch option {
        case .compact:
            return max(option.nominalWidth, floor)
        case .standard, .wide:
            return tabCount > shippedTabCount ? max(option.nominalWidth, floor) : option.nominalWidth
        }
    }

    /// How many tabs the header shows with every module at its shipped
    /// state on a Mac with a battery: five, the calendar being off until
    /// someone switches it on.
    public static let shippedTabCount =
        TabVisibility.visible(enabled: .shipped, hasBattery: true).count

    /// The text scale the open panel actually draws at: `requested`, or on
    /// a space too small for the panel it implies, the largest scale whose
    /// panel fits `size` -- never below one, never above `requested`.
    ///
    /// **Clamping only the frame clipped the text.** Larger on a small
    /// display used to cut the panel down to the screen while every font
    /// and text-holding length was still drawn at the full factor, so the
    /// bottom row ran off the panel. Bringing the scale itself down keeps
    /// the panel and its contents in proportion: the largest text that fits
    /// rather than larger text that does not.
    ///
    /// Searched on a grid of thousandths, starting half a point above the
    /// size (the slack `NotchType.length`'s rounding can take off a built
    /// frame), so the answer is a fixed point:
    /// asked again of the frame `panelFrame` built from it, it gives the
    /// same scale back. That lets a view read the scale from the panel's
    /// frame (`AppState.textScale`) and agree with the frame exactly,
    /// without the screen's metrics being threaded through to it.
    ///
    /// `nominalWidth` is the width the scale grows (`nominalPanelWidth`,
    /// "Panel width"); defaulted to the default panel's.
    public static func fittedTextScale(
        _ requested: CGFloat, within size: CGSize, nominalWidth: CGFloat = expandedSize.width
    ) -> CGFloat {
        func fits(_ scale: CGFloat) -> Bool {
            NotchType.length(nominalWidth, scale: scale) <= size.width
                && NotchType.length(expandedSize.height, scale: scale) <= size.height
        }
        guard requested.isFinite, requested > 1 else { return 1 }
        if fits(requested) { return requested }
        // Half a point of slack: `NotchType.length` rounds, so a frame
        // built at scale k can be up to half a point under k * expandedSize.
        // Without the slack a search over that frame would start below k
        // and read back a smaller scale; `fits` still rejects any start
        // that does not actually fit.
        let bound = min(
            requested,
            (size.width + 0.5) / nominalWidth,
            (size.height + 0.5) / expandedSize.height
        )
        guard bound.isFinite, bound > 1 else { return 1 }
        var thousandths = Int((bound * 1000).rounded(.down))
        while thousandths > 1000, !fits(CGFloat(thousandths) / 1000) {
            thousandths -= 1
        }
        return max(1, CGFloat(thousandths) / 1000)
    }
}
