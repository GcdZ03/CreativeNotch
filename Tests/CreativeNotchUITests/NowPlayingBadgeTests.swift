import AppKit
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// The ambient now-playing badge extends the closed notch into the right
/// ear, which is menu bar — so three separately-consumed rectangles have
/// to agree that it is there: what is drawn, what accepts clicks, and what
/// tracks hover. Two independent derivations of one rectangle is this
/// project's only Critical bug to date, so the agreement is asserted
/// directly rather than inferred from both sides calling the same function.
///
/// Same synthetic notched screen as `AppDelegateStateFunnelTests`: anchor
/// (2090, 1118, 230, 38) inside panel (1895, 896, 620, 260), i.e.
/// panel-local closed rect (195, 222, 230, 38).
@MainActor
struct NowPlayingBadgeTests {

    private static let closedRect = CGRect(x: 195, y: 222, width: 230, height: 38)
    /// 230 + 34, written out. Spelling it `230 +
    /// NotchGeometry.nowPlayingBadgeWidth` made every assertion below hold
    /// for whatever the constant happened to be — the production code
    /// handing the test the number it is checked against. The width is
    /// menu-bar real estate taken for as long as music plays, so it is
    /// pinned here and in `NowPlayingBadgeShapeTests`.
    private static let badgedRect = CGRect(x: 195, y: 222, width: 264, height: 38)

    private static let playing = TrackSnapshot(title: "Song", artist: "Band", isPlaying: true)
    private static let paused  = TrackSnapshot(title: "Song", artist: "Band", isPlaying: false)

    /// `NotchedDelegate.make` — the same screen and the same switched-off
    /// growth lag `TimerBadgeTests` and `TimerWiringTests` build on, so the
    /// widths the three suites pin are comparable by construction rather
    /// than by coincidence.
    private func makeDelegate() -> AppDelegate { NotchedDelegate.make() }

    // MARK: - The shape

    @Test func playingMusicWidensTheClosedShapeOnTheTrailingSide() {
        let delegate = makeDelegate()
        #expect(delegate.acceptedRect == Self.closedRect)

        delegate.nowPlayingDidChange(Self.playing)

        #expect(delegate.currentBadgeWidth == NotchGeometry.nowPlayingBadgeWidth)
        #expect(delegate.acceptedRect == Self.badgedRect)
        // Stated separately from the equality above so a rect that grew
        // the wrong way cannot pass as merely "wider".
        #expect(delegate.acceptedRect.minX == Self.closedRect.minX)
        #expect(delegate.acceptedRect.maxX > Self.closedRect.maxX)
    }

    /// Paused music is not playing music, and the badge answers "is
    /// something playing". Nothing about the closed notch may move.
    @Test func pausedMediaShowsNoBadge() {
        let delegate = makeDelegate()
        delegate.nowPlayingDidChange(Self.paused)

        #expect(delegate.currentBadgeWidth == 0)
        #expect(delegate.acceptedRect == Self.closedRect)
        #expect(delegate.hoverView?.trackingRect == Self.closedRect)
        #expect(NotchRootView.drawnRect(for: delegate.state).width == Self.closedRect.width)
    }

    /// Pausing has to take the badge away again, not just fail to add one:
    /// the re-sync runs on every publish, not only on the first.
    @Test func pausingAfterPlayingTakesTheBadgeBack() {
        let delegate = makeDelegate()
        delegate.nowPlayingDidChange(Self.playing)
        #expect(delegate.acceptedRect == Self.badgedRect)

        delegate.nowPlayingDidChange(Self.paused)
        #expect(delegate.acceptedRect == Self.closedRect)

        delegate.nowPlayingDidChange(Self.playing)
        #expect(delegate.acceptedRect == Self.badgedRect)

        // The helper reporting nothing at all is a third case.
        delegate.nowPlayingDidChange(nil)
        #expect(delegate.acceptedRect == Self.closedRect)
    }

    // MARK: - One derivation, three consumers

    /// The drawn rect, the hit-test region and the hover tracking rect,
    /// compared against each other while the badge is showing.
    ///
    /// `NotchRootView.drawnRect(for:)` is the view's own derivation, not
    /// one the test recomputes — otherwise this would only prove the test
    /// agrees with itself.
    @Test func theDrawnHitTestAndHoverRectsAgreeWhileTheBadgeShows() {
        let delegate = makeDelegate()
        delegate.nowPlayingDidChange(Self.playing)

        let drawn = NotchRootView.drawnRect(for: delegate.state)
        let accepted = delegate.acceptedRect
        let tracking = delegate.hoverView?.trackingRect

        // The drawn rect is in SwiftUI's top-left space; the other two are
        // panel-local bottom-left. Same rectangle, mirrored in y.
        #expect(drawn.size == accepted.size)
        #expect(drawn.minX == accepted.minX)
        #expect(drawn.minY == delegate.currentFrame.height - accepted.maxY)
        #expect(tracking == accepted)

        // And it is genuinely the badged shape, so this cannot pass with
        // all three agreeing on the un-badged one.
        #expect(drawn.width == 264)
    }

    /// The same agreement with nothing playing, which is the regression
    /// half: a badge width leaking into one consumer while nothing is
    /// playing would swallow menu bar clicks beside the notch forever.
    @Test func theSameRectsAgreeWithNothingPlaying() {
        let delegate = makeDelegate()

        let drawn = NotchRootView.drawnRect(for: delegate.state)
        #expect(drawn.size == Self.closedRect.size)
        #expect(delegate.acceptedRect == Self.closedRect)
        #expect(delegate.hoverView?.trackingRect == Self.closedRect)
    }

    // MARK: - The click actually lands

    /// End to end through the real hit test: a click in the strip the
    /// badge occupies is captured while music plays, and the identical
    /// click passes through to the menu bar when it does not.
    @Test func clicksOnTheBadgeAreCapturedAndOnlyWhileItIsThere() throws {
        let delegate = makeDelegate()
        let host = try #require(delegate.hostView)

        // Mid-strip: past the notch's trailing edge (x 425), inside the
        // badge (x 425...459), level with the notch band (y 222...260).
        let onBadge = NSPoint(x: 440, y: 240)

        #expect(host.hitTest(onBadge) == nil)

        delegate.nowPlayingDidChange(Self.playing)
        #expect(host.hitTest(onBadge) != nil)

        delegate.nowPlayingDidChange(nil)
        #expect(host.hitTest(onBadge) == nil)
    }

    /// The badge grows one side only, so the mirror-image point on the
    /// leading side must stay pass-through while music plays.
    @Test func clicksLeadingTheNotchStillPassThroughWhileMusicPlays() throws {
        let delegate = makeDelegate()
        let host = try #require(delegate.hostView)
        delegate.nowPlayingDidChange(Self.playing)

        // As far to the left of the notch as the badge extends to its right.
        let leading = NSPoint(x: 180, y: 240)
        #expect(host.hitTest(leading) == nil)
    }

    // MARK: - The badge does not disturb the other presentations

    /// Hovering still opens the peek, and clicking still opens the panel,
    /// at exactly the sizes they had before the badge existed.
    @Test func peekAndOpenAreUnaffectedByTheBadge() {
        let delegate = makeDelegate()
        delegate.nowPlayingDidChange(Self.playing)

        delegate.state.transition(to: .peek(.nowPlaying(Self.playing)))
        #expect(delegate.acceptedRect == CGRect(x: 85, y: 222, width: 450, height: 38))

        delegate.state.transition(to: .open(.shelf))
        #expect(delegate.acceptedRect == CGRect(x: 0, y: 0, width: 620, height: 260))

        delegate.state.transition(to: .closed)
        #expect(delegate.acceptedRect == Self.badgedRect)
    }
}
