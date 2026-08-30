import CoreGraphics
import Foundation
import Testing
@testable import CreativeNotchCore

struct BadgeSlotTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private let playing = TrackSnapshot(title: "T", artist: "A", isPlaying: true)
    private let paused  = TrackSnapshot(title: "T", artist: "A", isPlaying: false)

    private func running() -> Countdown {
        Countdown(duration: 1500, startingAt: t0)!
    }

    // MARK: - Who owns the slot
    //
    // Asserted as identities, not widths. Which badge is showing is what
    // the view needs, and a width can only answer it by being compared
    // against a constant — which is exactly what this module stopped
    // doing.

    @Test func nothingActiveMeansNoBadge() {
        #expect(NotchShape.badgeSlot(countdown: nil, nowPlaying: nil, at: t0) == BadgeSlot.none)
    }

    @Test func playingMediaAloneTakesTheSlot() {
        #expect(NotchShape.badgeSlot(countdown: nil, nowPlaying: playing, at: t0) == .nowPlaying)
    }

    @Test func pausedMediaAloneGivesNoBadge() {
        #expect(NotchShape.badgeSlot(countdown: nil, nowPlaying: paused, at: t0) == BadgeSlot.none)
    }

    @Test func aRunningTimerAloneTakesTheSlot() {
        #expect(NotchShape.badgeSlot(countdown: running(), nowPlaying: nil, at: t0) == .timer)
    }

    /// The rule from the spec: the timer owns the slot while it runs.
    @Test func aRunningTimerOutranksPlayingMedia() {
        #expect(NotchShape.badgeSlot(countdown: running(), nowPlaying: playing, at: t0) == .timer)
    }

    /// And gives it back, rather than keeping the slot forever.
    @Test func aFinishedTimerReturnsTheSlotToMedia() {
        let later = t0.addingTimeInterval(2000)
        #expect(NotchShape.badgeSlot(countdown: running(), nowPlaying: playing, at: later)
                == .nowPlaying)
    }

    @Test func aFinishedTimerWithNoMediaShowsNothing() {
        let later = t0.addingTimeInterval(2000)
        #expect(NotchShape.badgeSlot(countdown: running(), nowPlaying: nil, at: later)
                == BadgeSlot.none)
    }

    /// A paused timer still occupies the slot — it is still a timer you
    /// set, just not counting.
    @Test func aPausedTimerKeepsTheSlot() {
        let c = running().paused(at: t0.addingTimeInterval(100))
        #expect(NotchShape.badgeSlot(countdown: c, nowPlaying: playing,
                                     at: t0.addingTimeInterval(5000))
                == .timer)
    }

    // MARK: - How wide each slot is

    /// The widths themselves, where the width is the claim. Nothing else
    /// in this suite reads them: the identity is what the view branches
    /// on, and the width is only what the shape grows by.
    @Test func eachSlotReservesItsOwnWidth() {
        #expect(BadgeSlot.none.width == 0)
        #expect(BadgeSlot.nowPlaying.width == NotchGeometry.nowPlayingBadgeWidth)
        #expect(BadgeSlot.timer.width == NotchGeometry.timerBadgeWidth)
    }

    /// The timer badge has to hold a wider string than a 22pt cover.
    @Test func theTimerSlotIsWiderThanTheMediaSlot() {
        #expect(BadgeSlot.timer.width > BadgeSlot.nowPlaying.width)
        #expect(NotchGeometry.timerBadgeWidth > NotchGeometry.nowPlayingBadgeWidth)
    }

    // MARK: the refactor must not move today's geometry

    @Test func zeroWidthIsExactlyTheAnchorRect() {
        let anchor = Anchor.notch(CGRect(x: 500, y: 900, width: 200, height: 32))
        let frame = CGRect(x: 300, y: 700, width: 620, height: 260)
        let rect = NotchShape.visibleRect(
            presentation: .closed, anchor: anchor, panelFrame: frame, badgeWidth: 0
        )
        #expect(rect.width == 200)
    }

    @Test func aWidthGrowsOnlyTheTrailingSide() {
        let anchor = Anchor.notch(CGRect(x: 500, y: 900, width: 200, height: 32))
        let frame = CGRect(x: 300, y: 700, width: 620, height: 260)
        let plain = NotchShape.visibleRect(
            presentation: .closed, anchor: anchor, panelFrame: frame, badgeWidth: 0
        )
        let grown = NotchShape.visibleRect(
            presentation: .closed, anchor: anchor, panelFrame: frame, badgeWidth: 40
        )
        #expect(grown.minX == plain.minX)
        #expect(grown.width == plain.width + 40)
    }

    @Test func aPillIsNotGrownByAnyWidth() {
        let anchor = Anchor.pill(CGRect(x: 500, y: 900, width: 180, height: 32))
        let frame = CGRect(x: 300, y: 700, width: 620, height: 260)
        let plain = NotchShape.visibleRect(
            presentation: .closed, anchor: anchor, panelFrame: frame, badgeWidth: 0
        )
        let grown = NotchShape.visibleRect(
            presentation: .closed, anchor: anchor, panelFrame: frame, badgeWidth: 40
        )
        #expect(plain == grown)
    }
}
