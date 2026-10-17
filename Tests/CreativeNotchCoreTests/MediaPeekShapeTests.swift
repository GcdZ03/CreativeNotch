import Testing
import CoreGraphics
import Foundation
@testable import CreativeNotchCore

/// The music states' geometry (spec 2026-10-15): a cover in a leading ear
/// and bars in a trailing one while closed, and a peek that grows *down*
/// from the notch rather than sideways.
///
/// Every rect here comes from `NotchShape.visibleRect`, which the drawn
/// shape, the hit test and the hover tracking rect all read. A leading ear
/// that widened only the drawing would put a cover on screen that clicks
/// fall straight through.
struct MediaPeekShapeTests {

    // A real 14" MacBook: 179pt notch, 32pt menu bar.
    private let notch = Anchor.notch(CGRect(x: 646, y: 924, width: 179, height: 32))
    private let pill = Anchor.pill(CGRect(x: 500, y: 900, width: 180, height: 32))
    private let panel = CGRect(x: 425, y: 696, width: 620, height: 260)

    private var notchLocal: CGRect { CGRect(x: 221, y: 228, width: 179, height: 32) }

    // MARK: - The leading ear belongs to the slot

    @Test func onlyMediaClaimsALeadingEar() {
        #expect(BadgeSlot.nowPlaying.leadingWidth == NotchGeometry.nowPlayingBadgeWidth)
        #expect(BadgeSlot.none.leadingWidth == 0)
        #expect(BadgeSlot.timer.leadingWidth == 0)
        #expect(BadgeSlot.recording.leadingWidth == 0)
        #expect(BadgeSlot.capture.leadingWidth == 0)
    }

    @Test func omittingTheLeadingWidthLeavesTheShapeAsItWas() {
        let implicit = NotchShape.visibleRect(
            presentation: .closed, anchor: notch, panelFrame: panel,
            badgeWidth: NotchGeometry.nowPlayingBadgeWidth
        )
        #expect(implicit == CGRect(x: 221, y: 228, width: 179 + 34, height: 32))
    }

    /// Pinned to literals: the leading ear moves the origin left by exactly
    /// its width, and the trailing ear still grows the right side.
    @Test func musicGrowsTheClosedNotchOnBothSides() {
        let r = NotchShape.visibleRect(
            presentation: .closed, anchor: notch, panelFrame: panel,
            badgeWidth: BadgeSlot.nowPlaying.width,
            leadingBadgeWidth: BadgeSlot.nowPlaying.leadingWidth
        )
        #expect(r == CGRect(x: 221 - 34, y: 228, width: 34 + 179 + 34, height: 32))
    }

    /// A pill has no housing to avoid, so neither ear grows it.
    @Test func aPillIgnoresTheLeadingEar() {
        let plain = NotchShape.visibleRect(presentation: .closed, anchor: pill, panelFrame: panel)
        let badged = NotchShape.visibleRect(
            presentation: .closed, anchor: pill, panelFrame: panel,
            badgeWidth: 34, leadingBadgeWidth: 34
        )
        #expect(badged == plain)
    }

    // MARK: - The music peek is its own presentation

    @Test func aMusicPeekPresentsAsAMediaPeek() {
        let track = TrackSnapshot(title: "Song", artist: "Band", isPlaying: true)
        #expect(NotchState.peek(.nowPlaying(track)).presentation == .mediaPeek)
        #expect(NotchState.peek(.power(.pluggedIn(level: 50))).presentation == .statusPeek)
        #expect(NotchState.peek(.dragTarget).presentation == .peek)
    }

    /// Hangs from the notch's top edge, as wide as the other peeks, and
    /// `mediaPeekBodyHeight` taller than the notch.
    @Test func theMediaPeekGrowsDownFromTheNotch() {
        let r = NotchShape.visibleRect(presentation: .mediaPeek, anchor: notch, panelFrame: panel)
        let ear = NotchGeometry.peekEarWidth
        let body = NotchGeometry.mediaPeekBodyHeight
        #expect(r.minX == notchLocal.minX - ear)
        #expect(r.width == notchLocal.width + ear * 2)
        #expect(r.maxY == notchLocal.maxY)               // flush with the screen top
        #expect(r.height == notchLocal.height + body)
    }

    /// Centred on the pill the way `NotchGeometry.panelFrame` centres it.
    private let pillPanel = CGRect(x: 280, y: 672, width: 620, height: 260)

    @Test func onAPillTheMediaPeekHangsFromThePillsTopEdge() {
        let local = NotchShape.visibleRect(presentation: .closed, anchor: pill, panelFrame: pillPanel)
        let r = NotchShape.visibleRect(presentation: .mediaPeek, anchor: pill, panelFrame: pillPanel)
        #expect(r.midX == local.midX)
        #expect(r.maxY == local.maxY)
        #expect(r.height == local.height + NotchGeometry.mediaPeekBodyHeight)
    }

    /// The window never resizes, so a peek larger than it would be clipped.
    @Test func theMediaPeekFitsInsideThePanel() {
        for (anchor, frame) in [(notch, panel), (pill, pillPanel)] {
            let r = NotchShape.visibleRect(presentation: .mediaPeek, anchor: anchor, panelFrame: frame)
            #expect(CGRect(origin: .zero, size: frame.size).contains(r))
        }
    }

    @Test func theMediaPeekUsesThePanelRadiusWithASquareTop() {
        let r = NotchShape.cornerRadii(presentation: .mediaPeek, anchor: notch)
        #expect(r.topLeading == 0 && r.topTrailing == 0)
        #expect(r.bottomLeading == NotchGeometry.panelCornerRadius)
        #expect(r.bottomTrailing == NotchGeometry.panelCornerRadius)
    }

    // MARK: - The battery peek drops down too (2026-10-17)

    /// One row below the notch: as wide as the other peeks, hanging from
    /// the screen's top edge, `statusPeekBodyHeight` taller than the notch.
    @Test func theBatteryPeekGrowsDownFromTheNotch() {
        let r = NotchShape.visibleRect(presentation: .statusPeek, anchor: notch, panelFrame: panel)
        let ear = NotchGeometry.statusPeekEarWidth
        #expect(r.minX == notchLocal.minX - ear)
        #expect(r.width == notchLocal.width + ear * 2)
        #expect(r.maxY == notchLocal.maxY)
        #expect(r.height == notchLocal.height + NotchGeometry.statusPeekBodyHeight)
    }

    /// A single compact row, so shorter and narrower than the music player.
    @Test func theBatteryPeekIsSmallerThanTheMusicPeek() {
        #expect(NotchGeometry.statusPeekBodyHeight < NotchGeometry.mediaPeekBodyHeight)
        #expect(NotchGeometry.statusPeekEarWidth < NotchGeometry.peekEarWidth)
    }

    /// What the spring choice treats as a swap rather than a collapse.
    @Test func exactlyTheThreePeeksArePeeks() {
        #expect(NotchShape.Presentation.peek.isPeek)
        #expect(NotchShape.Presentation.statusPeek.isPeek)
        #expect(NotchShape.Presentation.mediaPeek.isPeek)
        #expect(!NotchShape.Presentation.closed.isPeek)
        #expect(!NotchShape.Presentation.expanded.isPeek)
    }

    @Test func theBatteryPeekUsesThePanelRadius() {
        #expect(NotchShape.cornerRadii(presentation: .statusPeek, anchor: notch)
                == NotchShape.cornerRadii(presentation: .mediaPeek, anchor: notch))
    }

    // MARK: - Which way the shape is moving

    /// The spring is chosen by direction, so the order has to be total and
    /// match how much of the panel each presentation draws.
    @Test func presentationsAreOrderedBySize() {
        #expect(NotchShape.Presentation.closed.rank < NotchShape.Presentation.peek.rank)
        #expect(NotchShape.Presentation.peek.rank < NotchShape.Presentation.statusPeek.rank)
        #expect(NotchShape.Presentation.statusPeek.rank < NotchShape.Presentation.mediaPeek.rank)
        #expect(NotchShape.Presentation.mediaPeek.rank < NotchShape.Presentation.expanded.rank)
    }
}
