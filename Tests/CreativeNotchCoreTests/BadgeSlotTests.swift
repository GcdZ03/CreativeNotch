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

    @Test func nothingActiveMeansNoBadge() {
        #expect(NotchShape.badgeWidth(countdown: nil, nowPlaying: nil, at: t0) == 0)
    }

    @Test func playingMediaAloneGivesTheMediaWidth() {
        #expect(NotchShape.badgeWidth(countdown: nil, nowPlaying: playing, at: t0)
                == NotchGeometry.nowPlayingBadgeWidth)
    }

    @Test func pausedMediaAloneGivesNoBadge() {
        #expect(NotchShape.badgeWidth(countdown: nil, nowPlaying: paused, at: t0) == 0)
    }

    @Test func aRunningTimerAloneGivesTheTimerWidth() {
        #expect(NotchShape.badgeWidth(countdown: running(), nowPlaying: nil, at: t0)
                == NotchGeometry.timerBadgeWidth)
    }

    /// The rule from the spec: the timer owns the slot while it runs.
    @Test func aRunningTimerOutranksPlayingMedia() {
        #expect(NotchShape.badgeWidth(countdown: running(), nowPlaying: playing, at: t0)
                == NotchGeometry.timerBadgeWidth)
    }

    /// And gives it back, rather than keeping the slot forever.
    @Test func aFinishedTimerReturnsTheSlotToMedia() {
        let later = t0.addingTimeInterval(2000)
        #expect(NotchShape.badgeWidth(countdown: running(), nowPlaying: playing, at: later)
                == NotchGeometry.nowPlayingBadgeWidth)
    }

    @Test func aFinishedTimerWithNoMediaShowsNothing() {
        let later = t0.addingTimeInterval(2000)
        #expect(NotchShape.badgeWidth(countdown: running(), nowPlaying: nil, at: later) == 0)
    }

    /// A paused timer still occupies the slot — it is still a timer you
    /// set, just not counting.
    @Test func aPausedTimerKeepsTheSlot() {
        let c = running().paused(at: t0.addingTimeInterval(100))
        #expect(NotchShape.badgeWidth(countdown: c, nowPlaying: playing,
                                      at: t0.addingTimeInterval(5000))
                == NotchGeometry.timerBadgeWidth)
    }

    /// The timer badge has to hold a wider string than a 22pt cover.
    @Test func theTimerSlotIsWiderThanTheMediaSlot() {
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
