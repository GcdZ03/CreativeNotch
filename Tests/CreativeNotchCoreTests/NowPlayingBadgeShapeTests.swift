import Testing
import CoreGraphics
import Foundation
@testable import CreativeNotchCore

/// The ambient now-playing badge widens the *closed* shape, because a
/// closed notch's rect is the camera housing and anything drawn inside it
/// is invisible.
///
/// The width lives in `visibleRect` and nowhere else: the drawn rect, the
/// hit-test region and the hover tracking rect all read this one function,
/// and a badge that widened only one of them would either swallow menu bar
/// clicks or drop clicks on itself through to whatever is behind.
struct NowPlayingBadgeShapeTests {

    // A real 14" MacBook: 179pt notch, 32pt menu bar.
    private let notch = Anchor.notch(CGRect(x: 646, y: 924, width: 179, height: 32))
    private let pill = Anchor.pill(CGRect(x: 500, y: 900, width: 180, height: 32))
    private let panel = CGRect(x: 425, y: 696, width: 620, height: 260)
    /// Fixed, so nothing here depends on the wall clock. No countdown is
    /// ever passed in this suite, so the instant is arbitrary.
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func closed(_ anchor: Anchor, badgeWidth: CGFloat) -> CGRect {
        NotchShape.visibleRect(
            presentation: .closed, anchor: anchor, panelFrame: panel, badgeWidth: badgeWidth
        )
    }

    // MARK: - Nothing playing changes nothing

    /// Pinned to literals, not to `closed(notch, badgeWidth: 0)` compared
    /// against itself: the whole promise is that a Mac with nothing
    /// playing gets byte-identical geometry to before this feature existed.
    @Test func theClosedNotchWithoutTheBadgeIsExactlyTheAnchor() {
        let r = closed(notch, badgeWidth: 0)
        #expect(r == CGRect(x: 221, y: 228, width: 179, height: 32))
    }

    /// The defaulted parameter must default to *off*. Existing callers
    /// that never heard of the badge keep the shape they had.
    @Test func omittingTheBadgeIsTheSameAsAskingForNoBadge() {
        let implicit = NotchShape.visibleRect(
            presentation: .closed, anchor: notch, panelFrame: panel
        )
        #expect(implicit == closed(notch, badgeWidth: 0))
    }

    // MARK: - The badge grows the trailing side, and only that

    /// "Wider" is not enough: a rect that grew off the *leading* side is
    /// also wider, and would put the badge under the app menus while the
    /// notch itself slid left. The origin must not move.
    @Test func theBadgeGrowsTheClosedNotchOnTheTrailingSideOnly() {
        let base = closed(notch, badgeWidth: 0)
        let badged = closed(notch, badgeWidth: NotchGeometry.nowPlayingBadgeWidth)

        #expect(badged.minX == base.minX)
        #expect(badged.minY == base.minY)
        #expect(badged.height == base.height)
        #expect(badged.width == base.width + NotchGeometry.nowPlayingBadgeWidth)
        #expect(badged.maxX == base.maxX + NotchGeometry.nowPlayingBadgeWidth)
    }

    /// The grown strip is on the right of the notch and nowhere else: a
    /// point just past the notch's trailing edge is inside the badged rect
    /// and outside the plain one, and its mirror image on the leading side
    /// is outside both.
    @Test func onlyThePointsTrailingTheNotchAreNewlyCaptured() {
        let base = closed(notch, badgeWidth: 0)
        let badged = closed(notch, badgeWidth: NotchGeometry.nowPlayingBadgeWidth)
        let y = base.midY

        let justTrailing = CGPoint(x: base.maxX + 4, y: y)
        #expect(badged.contains(justTrailing))
        #expect(!base.contains(justTrailing))

        let justLeading = CGPoint(x: base.minX - 4, y: y)
        #expect(!badged.contains(justLeading))
        #expect(!base.contains(justLeading))
    }

    /// The badge only exists on the closed notch. A peek or an open panel
    /// asked for it must be untouched, or hovering a badge would jump the
    /// shape by 34pt for no reason.
    @Test func theBadgeChangesNoOtherPresentation() {
        for presentation in [NotchShape.Presentation.peek, .expanded] {
            let plain = NotchShape.visibleRect(
                presentation: presentation, anchor: notch, panelFrame: panel, badgeWidth: 0
            )
            let badged = NotchShape.visibleRect(
                presentation: presentation, anchor: notch, panelFrame: panel,
                badgeWidth: NotchGeometry.nowPlayingBadgeWidth
            )
            #expect(plain == badged, "\(presentation) must ignore the badge")
        }
    }

    /// The width itself, pinned to the number.
    ///
    /// Every other assertion here is written as `base.width +
    /// NotchGeometry.nowPlayingBadgeWidth`, so all of them hold for
    /// whatever the constant happens to be — the production code handing
    /// the test the value it is checked against. This one does not. 34pt
    /// is menu bar taken for as long as music plays, and it is exactly the
    /// room `NowPlayingBadgeView`'s 22pt cover needs with 6pt gutters:
    /// `BadgeRenderingTests` pins that split against the drawn pixels, so
    /// moving this number without moving the tile fails there too.
    @Test func theBadgeIsThirtyFourPointsWide() {
        #expect(NotchGeometry.nowPlayingBadgeWidth == 34)
    }

    /// The intrusion is menu bar, taken for as long as music plays, so it
    /// has to stay far smaller than a peek's ear — which is transient.
    @Test func theBadgeIsMuchNarrowerThanAPeekEar() {
        #expect(NotchGeometry.nowPlayingBadgeWidth > 0)
        #expect(NotchGeometry.nowPlayingBadgeWidth < NotchGeometry.peekEarWidth / 2)
    }

    // MARK: - A notchless Mac

    /// A pill has no camera housing to draw around and no menu bar
    /// underneath it, and its closed rect currently shows nothing at all —
    /// so the badge renders inside it and the geometry does not move.
    @Test func aPillIsNotGrownByTheBadge() {
        let badged = closed(pill, badgeWidth: NotchGeometry.nowPlayingBadgeWidth)
        #expect(badged == closed(pill, badgeWidth: 0))
        #expect(badged == CGRect(x: 75, y: 204, width: 180, height: 32))
    }

    // MARK: - Who takes the slot, and how wide it then is

    @Test func playingMediaShowsTheBadge() {
        let track = TrackSnapshot(title: "t", artist: "a", isPlaying: true)
        let slot = NotchShape.badgeSlot(countdown: nil, nowPlaying: track, at: now)
        #expect(slot == .nowPlaying)
        #expect(slot.width == NotchGeometry.nowPlayingBadgeWidth)
    }

    /// The badge answers "is something playing". Over a paused track it
    /// would be a lie, so paused media shows nothing.
    @Test func pausedMediaShowsNoBadge() {
        let track = TrackSnapshot(title: "t", artist: "a", isPlaying: false)
        let slot = NotchShape.badgeSlot(countdown: nil, nowPlaying: track, at: now)
        #expect(slot == BadgeSlot.none)
        #expect(slot.width == 0)
    }

    @Test func nothingPlayingShowsNoBadge() {
        #expect(NotchShape.badgeSlot(countdown: nil, nowPlaying: nil, at: now) == BadgeSlot.none)
    }

    /// The end-to-end shape of the paused case: the slot is empty, so its
    /// width is zero and the closed rect is the untouched anchor.
    @Test func aPausedTrackLeavesTheClosedNotchExactlyAsItWas() {
        let paused = TrackSnapshot(title: "t", artist: "a", isPlaying: false)
        let r = closed(notch, badgeWidth: NotchShape.badgeSlot(
            countdown: nil, nowPlaying: paused, at: now
        ).width)
        #expect(r == closed(notch, badgeWidth: 0))
        #expect(r.width == 179)
    }
}
