import CoreGraphics
import Foundation

/// What occupies the trailing badge slot, if anything.
///
/// An identity rather than a width, because the width alone cannot say
/// *which* badge is showing without comparing it to a constant — and that
/// makes two independent constants load-bearing as distinct values. The
/// drawn content and the reserved width must come from one answer.
public enum BadgeSlot: Equatable, Sendable {
    case none
    case nowPlaying
    case timer
    case recording
    case capture
    case downloads
    /// A stopwatch that has been started and not reset (2026-10-29).
    case stopwatch

    /// How far the closed notch grows for this slot.
    public var width: CGFloat {
        switch self {
        case .none:       return 0
        case .nowPlaying: return NotchGeometry.nowPlayingBadgeWidth
        case .timer:      return NotchGeometry.timerBadgeWidth
        case .recording:  return NotchGeometry.recordingBadgeWidth
        case .capture:    return NotchGeometry.captureBadgeWidth
        case .downloads:  return NotchGeometry.downloadsBadgeWidth
        case .stopwatch:  return NotchGeometry.stopwatchBadgeWidth
        }
    }

    /// How far the closed notch grows on its *leading* side for this slot.
    ///
    /// No slot claims one any more. Media did from 2026-10-15 to 2026-10-17,
    /// with its cover left of the notch, until that was seen covering app
    /// menus; it now shares the trailing ear with its bars. Kept as a
    /// property of the slot, threaded through `visibleRect`, so a badge that
    /// ever needs the left again is one decision rather than a second rule.
    public var leadingWidth: CGFloat {
        switch self {
        case .none, .nowPlaying, .timer, .recording, .capture, .downloads, .stopwatch: return 0
        }
    }
}

extension Array where Element == BadgeSlot {
    /// How far the closed notch grows for all of these at once: one shape,
    /// every segment's width.
    public var totalWidth: CGFloat { reduce(0) { $0 + $1.width } }

    /// These, less the least important until they fit `room` (2026-10-29),
    /// in their order from the notch out. The stopwatch goes first, then
    /// downloads, music and the timer; the privacy dot never, even past the
    /// room, because it is the one thing here the user cannot see any other
    /// way.
    public func fitting(_ room: CGFloat) -> [BadgeSlot] {
        let dropOrder: [BadgeSlot] = [.stopwatch, .downloads, .nowPlaying, .timer]
        var kept = self
        for slot in dropOrder where kept.totalWidth > room {
            kept.removeAll { $0 == slot }
        }
        return kept
    }
}

/// One segment of the closed notch's trailing ear: an activity and where it
/// is, panel-local with a bottom-left origin like `visibleRect`.
public struct BadgeSegment: Equatable, Sendable {
    public let slot: BadgeSlot
    public let rect: CGRect

    public init(slot: BadgeSlot, rect: CGRect) {
        self.slot = slot
        self.rect = rect
    }
}

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
        /// The battery peek: one row hanging below the notch (2026-10-17),
        /// so the icon, its words, the bar and the percentage read together
        /// instead of being split by the camera housing.
        case statusPeek
        /// The music peek: grows down from the notch into a mini player,
        /// where `.peek` grows sideways and keeps the notch's height.
        case mediaPeek
        case expanded

        /// Orders presentations by how much of the panel they draw, so the
        /// view can tell a growing change from a shrinking one and pick
        /// its spring accordingly.
        public var rank: Int {
            switch self {
            case .closed:    return 0
            case .peek:       return 1
            case .statusPeek: return 2
            case .mediaPeek:  return 3
            case .expanded:   return 4
            }
        }

        /// Any of the three peeks: what hover or an event shows briefly,
        /// between the closed notch and the panel.
        public var isPeek: Bool {
            switch self {
            case .peek, .statusPeek, .mediaPeek: return true
            case .closed, .expanded:             return false
            }
        }
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
    ///
    /// `corners` is "Corners" in Settings (2026-10-24), and rounds the open
    /// panel only: the closed notch has to keep matching the hardware cutout,
    /// and a peek is sized into the housing's band (`PanelCorners`).
    public static func cornerRadii(
        presentation: Presentation, anchor: Anchor, corners: PanelCorners = .default
    ) -> CornerRadii {
        let panel = presentation == .expanded ? corners.radius : NotchGeometry.panelCornerRadius
        guard anchor.isNotch else {
            // A pill floats in the menu bar with nothing to merge into.
            let r = panel
            return CornerRadii(topLeading: r, bottomLeading: r, bottomTrailing: r, topTrailing: r)
        }

        // Anything on a notch is flush with the screen's top edge, so its
        // top corners never round — that would leave wedges of desktop
        // showing above the panel.
        let bottom = presentation == .closed
            ? NotchGeometry.notchCornerRadius   // match the hardware cutout
            : panel                             // now it is a panel, not the notch
        return CornerRadii(
            topLeading: 0,
            bottomLeading: bottom,
            bottomTrailing: bottom,
            topTrailing: 0
        )
    }

    /// Which badge owns the trailing slot.
    ///
    /// One function, because "which badge is showing" and "how wide is the
    /// slot" are one decision. Two spellings of it would drift exactly as
    /// two spellings of the rect would — and the drawn rect, the hit test
    /// and the hover tracking rect all derive from `.width`.
    ///
    /// **A recording outranks everything**, and that ordering is the whole
    /// reason the camera's exemption from the activity gate is defensible. A
    /// capture that outlives the panel runs with the camera light on and
    /// nothing else to explain it; this badge is the explanation, and it
    /// cannot be the thing that yields to a track starting.
    ///
    /// Below it, a running or paused timer owns the slot, then downloads in
    /// progress; media takes it back when both are done. Paused *media*
    /// shows nothing: the badge answers "is something playing".
    ///
    /// `hidden` is the badges switched off in Settings (2026-10-24,
    /// `LayoutOptions.hiddenBadges`). A hidden badge is passed over as if it
    /// had nothing to show, so the next one down takes the slot. It is
    /// consulted for the timer, downloads and media only: the recording dot
    /// is the camera exemption's explanation, above, and the capture indicator is a
    /// module whose whole output is this badge, with its own switch -- hiding
    /// either here would be a second, quieter way to lose a privacy signal.
    public static func badgeSlot(
        countdown: Countdown?,
        nowPlaying: TrackSnapshot?,
        isRecording: Bool = false,
        capture: CaptureUse = .none,
        downloads: DownloadSummary? = nil,
        hiding hidden: Set<BadgeSlot> = [],
        at now: Date
    ) -> BadgeSlot {
        if isRecording { return .recording }
        // **Above the timer and above media.** Something else is using the
        // camera or the microphone right now, and that is the one thing in
        // this list the user cannot find out any other way -- a countdown they
        // set themselves and a track they are playing are both already known
        // to them. It sits below `.recording` only because that is this app's
        // own capture, which is the more specific claim about the same fact.
        if capture.isAnythingCapturing { return .capture }
        if !hidden.contains(.timer), let countdown, !countdown.hasFinished(at: now) { return .timer }
        // Below a countdown, which is a deadline the user set; above a
        // playing track, which is already on the speakers. The ring is the
        // only place a download's progress shows without opening anything.
        if !hidden.contains(.downloads), downloads != nil { return .downloads }
        if !hidden.contains(.nowPlaying), nowPlaying?.isPlaying == true { return .nowPlaying }
        return .none
    }

    /// Every activity beside the notch at once, ordered from the notch out
    /// (2026-10-29): music keeps the bar nearest the notch, then the timer,
    /// the stopwatch and downloads, and the privacy dot -- this app's
    /// recording, or another app's camera or microphone -- at the far end,
    /// where macOS keeps its own. They share one shape, so the drawn rect,
    /// the hit test and the hover rect still grow from one width
    /// (`totalWidth`), and nothing outranks anything any more: a timer no
    /// longer takes the music's place.
    ///
    /// `hidden` passes over the music, the timer (the stopwatch with it) and
    /// downloads, and never the privacy dot, for `badgeSlot`'s reasons.
    public static func badgeSlots(
        countdown: Countdown?,
        stopwatch: Stopwatch = Stopwatch(),
        nowPlaying: TrackSnapshot?,
        isRecording: Bool = false,
        capture: CaptureUse = .none,
        downloads: DownloadSummary? = nil,
        hiding hidden: Set<BadgeSlot> = [],
        fitting room: CGFloat = .infinity,
        at now: Date
    ) -> [BadgeSlot] {
        var slots: [BadgeSlot] = []
        if !hidden.contains(.nowPlaying), nowPlaying?.isPlaying == true { slots.append(.nowPlaying) }
        if !hidden.contains(.timer), let countdown, !countdown.hasFinished(at: now) { slots.append(.timer) }
        if !hidden.contains(.timer), !stopwatch.isReset { slots.append(.stopwatch) }
        if !hidden.contains(.downloads), downloads != nil { slots.append(.downloads) }
        if isRecording {
            slots.append(.recording)
        } else if capture.isAnythingCapturing {
            slots.append(.capture)
        }
        return slots.fitting(room)
    }

    /// How wide the segments beside the notch may grow: as far as the panel
    /// window reaches (2026-10-29). The window is centred on the anchor and
    /// never resizes, so past half its width, less half the notch, a segment
    /// would be cut off and its clicks would land nowhere. A pill grows both
    /// ways about its centre, so the whole panel width is its room.
    public static func badgeRoom(anchor: Anchor, panelFrame: CGRect) -> CGFloat {
        anchor.isNotch ? max((panelFrame.width - anchor.rect.width) / 2, 0) : panelFrame.width
    }

    /// Where each of `slots` is drawn, in order. On a notch they run out
    /// from the housing's trailing edge; on a pill they fill the pill,
    /// centred, as `visibleRect` sizes it. As tall as the anchor's band, so
    /// a lyrics strip below belongs to no segment.
    public static func badgeSegments(_ slots: [BadgeSlot], anchor: Anchor, panelFrame: CGRect) -> [BadgeSegment] {
        let shape = visibleRect(presentation: .closed, anchor: anchor, panelFrame: panelFrame, badgeWidth: slots.totalWidth)
        let band = CGRect(
            x: shape.minX, y: anchor.rect.minY - panelFrame.minY, width: shape.width, height: anchor.rect.height
        )
        var x = anchor.isNotch ? band.maxX - slots.totalWidth : band.midX - slots.totalWidth / 2
        return slots.map { slot in
            defer { x += slot.width }
            return BadgeSegment(slot: slot, rect: CGRect(x: x, y: band.minY, width: slot.width, height: band.height))
        }
    }

    /// The segment under `point`, or `nil` over the housing, the strip, or
    /// nothing at all.
    public static func segment(at point: CGPoint, in segments: [BadgeSegment]) -> BadgeSlot? {
        segments.first { $0.rect.contains(point) }?.slot
    }

    /// Panel-local, bottom-left origin, y increasing upward — matching an
    /// unflipped `NSView`.
    ///
    /// `badgeWidth` is defaulted so the three consumers that must agree —
    /// the drawn rect, the hit test and the hover tracking rect — all widen
    /// from this one function rather than each adding the badge's width
    /// themselves.
    ///
    /// Any non-positive `badgeWidth` means "no badge", zero and negative
    /// alike. Documented rather than clamped or trapped: `BadgeSlot.width`
    /// gates every real caller and can only return 0, 34 or 44, so a clamp
    /// would be unreachable code asserting nothing, and a trap would add a
    /// crash path to the closed notch's redraw. The parameter is public and
    /// defaulted, though, so the rule is stated here rather than left to be
    /// inferred from the `> 0` below.
    ///
    /// `lyricsHeight` is one line of lyrics, or zero (spec 2026-10-29). It
    /// grows the closed notch down into a strip, and the music peek's body
    /// by a row; every other presentation, and a closed pill, ignore it.
    public static func visibleRect(
        presentation: Presentation,
        anchor: Anchor,
        panelFrame: CGRect,
        badgeWidth: CGFloat = 0,
        leadingBadgeWidth: CGFloat = 0,
        lyricsHeight: CGFloat = 0
    ) -> CGRect {
        let lyrics = max(lyricsHeight, 0)
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
            // A pill has no camera housing, so it is not grown to one side:
            // it *is* the badge. Idle it shows nothing, so it is a small
            // capsule at the anchor's centre, `pillIdleWidth`; with a badge
            // it is the badge's width, about the same centre (2026-10-26).
            // In the menu bar, the full empty 180pt covered app menus on a
            // narrow display.
            //
            // Non-positive is "no badge" — see the doc comment above.
            //
            // No lyrics strip on a pill (spec 2026-10-29): it sits inside
            // the menu bar, and one rect grown down by a line would be the
            // line's width at the menu bar's height too, over the app menus.
            //
            // Media is the one exception to "trailing only": its cover
            // takes a leading ear while the equalizer takes the trailing
            // one (spec 2026-10-15, "Reversed after the fact").
            guard anchor.isNotch else {
                let badge = max(badgeWidth, 0) + max(leadingBadgeWidth, 0)
                let width = max(NotchGeometry.pillIdleWidth, badge)
                return CGRect(
                    x: local.midX - width / 2,
                    y: local.minY,
                    width: width,
                    height: local.height
                )
            }
            // The lyrics strip hangs below the housing and the badge
            // together (spec 2026-10-29), flush with the screen's top edge
            // like every other shape here. Notch only: see the pill above,
            // which has no strip because it would cover app menus.
            let trailing = max(badgeWidth, 0)
            let leading = max(leadingBadgeWidth, 0)
            return CGRect(
                x: local.minX - leading,
                y: local.minY - lyrics,
                width: leading + local.width + trailing,
                height: local.height + lyrics
            )

        case .mediaPeek, .statusPeek:
            // Grows down rather than sideways: the top band keeps the
            // notch's height, so its ears stay clear of the housing, and
            // the content hangs below it. Centred on the anchor and flush
            // with its top edge, on a notch and on a pill alike.
            let isMedia = presentation == .mediaPeek
            let ear = isMedia ? NotchGeometry.peekEarWidth : NotchGeometry.statusPeekEarWidth
            let body = isMedia ? NotchGeometry.mediaPeekBodyHeight + lyrics : NotchGeometry.statusPeekBodyHeight
            let height = local.height + body
            return CGRect(
                x: local.minX - ear,
                y: local.maxY - height,
                width: local.width + ear * 2,
                height: height
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
