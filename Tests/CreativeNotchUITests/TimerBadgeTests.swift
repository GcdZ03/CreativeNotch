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

    private static let notched = ScreenMetrics(
        frame: CGRect(x: 1470, y: 200, width: 1470, height: 956),
        safeAreaTopInset: 38,
        auxiliaryTopLeftWidth: 620,
        auxiliaryTopRightWidth: 620,
        menuBarHeight: 38
    )

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

    /// The media badge's rect, for the ranking test: 230 + 34.
    private static let mediaRect = CGRect(x: 195, y: 222, width: 264, height: 38)

    private static let playing = TrackSnapshot(title: "Song", artist: "Band", isPlaying: true)

    /// 25 minutes from the wall clock, so it is still running at every
    /// `Date()` any of these tests takes — `NotchRootView.drawnRect(for:)`
    /// and `AppDelegate.currentBadgeWidth` each read the clock themselves.
    private static func running() -> Countdown {
        Countdown(duration: 1500, startingAt: Date())!
    }

    /// The countdown is set *before* `install`, which seeds the accepted
    /// region from `visibleRect()` directly. There is no countdown re-sync
    /// hook on `AppDelegate` yet — the scheduler that will need one is a
    /// later task — so seeding at install is how a test reaches the badged
    /// state without inventing behaviour the app does not have.
    ///
    /// The growth lag has its own suite; the delay is switched off so every
    /// sync here is synchronous, as in `NowPlayingBadgeTests`.
    private func makeDelegate(countdown: Countdown? = nil) -> AppDelegate {
        let delegate = AppDelegate()
        delegate.growthDelay = .zero
        delegate.state.countdown = countdown
        delegate.install(metrics: Self.notched)
        return delegate
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

    /// The timer outranks playing media in all three rects, not just in the
    /// pure function.
    ///
    /// This drives the real publish path: the countdown is already set when
    /// `nowPlayingDidChange` re-syncs, so the slot is decided with both
    /// claimants present. 274, not 264 — if the hit test resolved the tie
    /// the other way the user would see a countdown 10pt wider than the
    /// region that accepts clicks on it.
    @Test func aRunningTimerOutranksPlayingMediaInAllThreeRects() {
        let delegate = makeDelegate(countdown: Self.running())
        delegate.nowPlayingDidChange(Self.playing)

        #expect(delegate.acceptedRect == Self.timedRect)
        #expect(delegate.hoverView?.trackingRect == Self.timedRect)
        #expect(NotchRootView.drawnRect(for: delegate.state).width == Self.timedRect.width)
        #expect(Self.timedRect.width > Self.mediaRect.width)
    }

    // MARK: - The click actually lands

    /// End to end through the real hit test, on the 10pt sliver that is the
    /// whole point of this suite.
    ///
    /// x 459...469 is the part of the countdown's slot that reaches *past*
    /// where the media badge would end. A click there is captured while a
    /// timer runs and passes through to the menu bar when none does. If
    /// `AppDelegate` ever computes its badge width without the countdown,
    /// this is the strip the user watches their clicks fall through.
    @Test func clicksOnTheCountdownsOwnSliverAreCaptured() throws {
        // Mid-sliver: past where a 34pt media badge would end (x 459),
        // inside the timer's 44pt slot (ends x 469), level with the notch
        // band (y 222...260).
        let onSliver = NSPoint(x: 464, y: 240)

        let idle = makeDelegate()
        #expect(try #require(idle.hostView).hitTest(onSliver) == nil)

        // Nor does *playing media* reach it — the sliver belongs to the
        // timer alone, so this cannot pass by way of the media badge.
        idle.nowPlayingDidChange(Self.playing)
        #expect(try #require(idle.hostView).hitTest(onSliver) == nil)

        let timed = makeDelegate(countdown: Self.running())
        #expect(try #require(timed.hostView).hitTest(onSliver) != nil)
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

        delegate.state.transition(to: .peek(.nowPlaying(Self.playing)))
        #expect(delegate.acceptedRect == CGRect(x: 85, y: 222, width: 450, height: 38))

        delegate.state.transition(to: .open(.shelf))
        #expect(delegate.acceptedRect == CGRect(x: 0, y: 0, width: 620, height: 260))

        delegate.state.transition(to: .closed)
        #expect(delegate.acceptedRect == Self.timedRect)
    }
}
