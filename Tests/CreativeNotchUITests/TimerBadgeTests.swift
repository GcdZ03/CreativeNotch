import AppKit
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// The countdown's half of `NowPlayingBadgeTests`.
///
/// The timer shares the trailing ear with the album cover, and it takes
/// 44pt rather than 34 — so the same three rectangles that have to agree
/// about the media badge have to agree about a *wider* one here: what is
/// drawn, what accepts clicks, and what tracks hover.
///
/// Why this suite exists at all. The media path is pinned end-to-end by the
/// literal `264` in `NowPlayingBadgeTests`, `GrowthLagTests` and
/// `BadgeRenderingTests`; the timer path had no equivalent, and a review
/// showed `AppDelegate.currentBadgeWidth` could be severed from the
/// countdown entirely — `countdown: nil` — with all 575 tests still green.
/// That is harmless only for as long as nothing writes `app.countdown`. The
/// moment the scheduler does, `NotchRootView` draws 230 + 44 = 274pt while
/// the hit test accepts 264 or 230, and the trailing 10pt of a *visible*
/// countdown drops clicks straight through to the menu bar and never
/// registers hover. Two independent derivations of one rectangle is this
/// project's only Critical bug to date.
///
/// Same synthetic notched screen as `NowPlayingBadgeTests`: anchor
/// (2090, 1118, 230, 38) inside panel (1895, 896, 620, 260), i.e.
/// panel-local closed rect (195, 222, 230, 38).
@MainActor
struct TimerBadgeTests {

    private static let closedRect = CGRect(x: 195, y: 222, width: 230, height: 38)

    /// 230 + 44, written out. Spelling it `230 +
    /// NotchGeometry.timerBadgeWidth` would make every assertion below hold
    /// for whatever the constant happened to be — the production code
    /// handing the test the number it is checked against. This is the only
    /// place `timerBadgeWidth == 44` is pinned as a drawn consequence, and
    /// the width is menu-bar real estate taken for as long as the timer
    /// runs, so it is pinned by literal exactly as `264` is on the media
    /// side.
    private static let timedRect = CGRect(x: 195, y: 222, width: 274, height: 38)

    /// The media badge's rect, for the ranking test: 230 + 68 — the cover
    /// and the equalizer together in the trailing ear.
    private static let mediaRect = CGRect(x: 195, y: 222, width: 298, height: 38)

    /// Music and a timer side by side (2026-10-29): 230 + 68 + 44.
    private static let bothRect = CGRect(x: 195, y: 222, width: 342, height: 38)

    private static let playing = TrackSnapshot(title: "Song", artist: "Band", isPlaying: true)

    /// 25 minutes from the wall clock, so it is still running at every
    /// `Date()` any of these tests takes — `NotchRootView.drawnRect(for:)`
    /// and `AppDelegate.currentBadgeWidth` each read the clock themselves.
    private static func running() -> Countdown {
        Countdown(duration: 1500, startingAt: Date())!
    }

    /// The countdown is set *before* `install`, which seeds the accepted
    /// region from `visibleRect()` directly — reaching the badged state
    /// without a scheduler running.
    ///
    /// This suite pins the shape. `TimerWiringTests` pins the same 274
    /// through the real `countdownDidChange` re-sync, which is the path the
    /// running app actually takes; both are needed, because seeding at
    /// install cannot catch a missing re-sync and the re-sync test cannot
    /// catch a badge that was never in `visibleRect`.
    private func makeDelegate(countdown: Countdown? = nil) -> AppDelegate {
        NotchedDelegate.make(countdown: countdown)
    }

    // MARK: - One derivation, three consumers

    /// The drawn rect, the hit-test region and the hover tracking rect,
    /// compared against each other while a countdown is running.
    ///
    /// `NotchRootView.drawnRect(for:)` is the view's own derivation, not one
    /// the test recomputes — otherwise this would only prove the test agrees
    /// with itself. The width is pinned separately so it cannot pass with
    /// all three agreeing on the *un*-badged shape, which is exactly what
    /// happens when `AppDelegate` goes blind to the countdown.
    @Test func theDrawnHitTestAndHoverRectsAgreeWhileTheCountdownShows() {
        let delegate = makeDelegate(countdown: Self.running())

        let drawn = NotchRootView.drawnRect(for: delegate.state)
        let accepted = delegate.acceptedRect
        let tracking = delegate.hoverView?.trackingRect

        // The drawn rect is in SwiftUI's top-left space; the other two are
        // panel-local bottom-left. Same rectangle, mirrored in y.
        #expect(drawn.size == accepted.size)
        #expect(drawn.minX == accepted.minX)
        #expect(drawn.minY == delegate.currentFrame.height - accepted.maxY)
        #expect(tracking == accepted)

        // And it is genuinely the timer's shape — 274, not 264 and not 230.
        #expect(accepted == Self.timedRect)
        #expect(drawn.width == 274)
        #expect(delegate.currentBadgeWidth == NotchGeometry.timerBadgeWidth)
    }

    /// The regression half: with no countdown, nothing may have grown.
    /// A badge width leaking into one consumer while no timer runs would
    /// swallow menu bar clicks beside the notch forever.
    @Test func theSameRectsAgreeWithNoCountdown() {
        let delegate = makeDelegate()

        #expect(NotchRootView.drawnRect(for: delegate.state).width == Self.closedRect.width)
        #expect(delegate.acceptedRect == Self.closedRect)
        #expect(delegate.hoverView?.trackingRect == Self.closedRect)
        #expect(delegate.currentBadgeWidth == 0)
    }

    /// A running timer and playing media both show (2026-10-29), and all
    /// three rects grow by both segments, not just the pure function.
    ///
    /// This drives the real publish path: the countdown is already set when
    /// `nowPlayingDidChange` re-syncs. 342 -- if any consumer still took
    /// only one of the two it would be 274 or 298, and clicks on a segment
    /// the user can see would fall through.
    @Test func aRunningTimerAndPlayingMediaGrowAllThreeRectsTogether() {
        let delegate = makeDelegate(countdown: Self.running())
        delegate.nowPlayingDidChange(Self.playing)

        #expect(delegate.acceptedRect == Self.bothRect)
        #expect(delegate.hoverView?.trackingRect == Self.bothRect)
        #expect(NotchRootView.drawnRect(for: delegate.state).width == Self.bothRect.width)
        #expect(Self.bothRect != Self.timedRect && Self.bothRect != Self.mediaRect)
    }

    // MARK: - The click actually lands

    /// End to end through the real hit test, on both sides of where the
    /// second segment ends (2026-10-29).
    ///
    /// The music's 68pt segment runs from x 425 to 493 and the timer's 44pt
    /// from there to x 537. A click at x 520 lands on the timer; one at 545
    /// is past both and must fall through to the menu bar.
    @Test func bothSegmentsTakeClicksAndNothingPastThem() throws {
        let onTimer = NSPoint(x: 520, y: 240)
        let pastBoth = NSPoint(x: 545, y: 240)

        let idle = makeDelegate()
        #expect(try #require(idle.hostView).hitTest(onTimer) == nil)

        let timed = makeDelegate(countdown: Self.running())
        timed.nowPlayingDidChange(Self.playing)
        let host = try #require(timed.hostView)
        #expect(host.hitTest(onTimer) != nil)
        #expect(host.hitTest(pastBoth) == nil)
    }

    /// The countdown grows one side only, so the mirror-image point on the
    /// leading side must stay pass-through while it runs.
    @Test func clicksLeadingTheNotchStillPassThroughWhileATimerRuns() throws {
        let delegate = makeDelegate(countdown: Self.running())
        let host = try #require(delegate.hostView)

        // As far to the left of the notch as the countdown extends to its
        // right.
        #expect(host.hitTest(NSPoint(x: 170, y: 240)) == nil)
    }

    // MARK: - The countdown does not disturb the other presentations

    /// Hovering still opens the peek, and clicking still opens the panel,
    /// at exactly the sizes they had before the badge existed. Only the
    /// *closed* shape grows.
    @Test func peekAndOpenAreUnaffectedByTheCountdown() {
        let delegate = makeDelegate(countdown: Self.running())

        // The music peek grows down from the notch (spec 2026-10-15): as
        // wide as the other peeks, `mediaPeekBodyHeight` (100) taller.
        delegate.state.transition(to: .peek(.nowPlaying(Self.playing)))
        #expect(delegate.acceptedRect == CGRect(x: 85, y: 122, width: 450, height: 138))

        delegate.state.transition(to: .open(.shelf))
        #expect(delegate.acceptedRect == CGRect(x: 0, y: 0, width: 620, height: 260))

        delegate.state.transition(to: .closed)
        #expect(delegate.acceptedRect == Self.timedRect)
    }
}
