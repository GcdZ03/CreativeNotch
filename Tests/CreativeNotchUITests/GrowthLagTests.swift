import AppKit
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// The accepted region — what the hit test and the hover tracker use — must
/// never describe more than is drawn.
///
/// The panel animates open over ~320ms while the derived rects used to snap
/// to full size instantly, so for that window the app accepted clicks on a
/// region that was not visibly there yet. Shrinking early is harmless
/// (clicks fall through a panel still visibly collapsing); growing early is
/// not. (Follow-up F6.)
@MainActor
struct GrowthLagTests {

    private static let notched = ScreenMetrics(
        frame: CGRect(x: 1470, y: 200, width: 1470, height: 956),
        safeAreaTopInset: 38,
        auxiliaryTopLeftWidth: 620,
        auxiliaryTopRightWidth: 620,
        menuBarHeight: 38
    )

    private static let closedRect = CGRect(x: 195, y: 222, width: 230, height: 38)
    private static let openRect   = CGRect(x: 0, y: 0, width: 620, height: 260)
    /// 230 + the badge's 34, written out rather than derived from the
    /// constant the production code uses. See `NowPlayingBadgeTests`.
    private static let badgedRect = CGRect(x: 195, y: 222, width: 264, height: 38)

    private static let playing = TrackSnapshot(title: "Song", artist: "Band", isPlaying: true)

    /// Awaits the pending growth rather than sleeping past it. Sleeping
    /// raced the scheduler — green locally, red on a loaded CI runner.
    private func settle(_ delegate: AppDelegate) async {
        await delegate.growthTask?.value
    }

    private func makeDelegate(delay: Duration = .milliseconds(60)) -> AppDelegate {
        let delegate = AppDelegate()
        delegate.growthDelay = delay
        delegate.install(metrics: Self.notched)
        return delegate
    }

    @Test func theShippedDelayMatchesTheExpandAnimation() {
        #expect(AppDelegate.defaultGrowthDelay == .milliseconds(320))
        #expect(AppDelegate().growthDelay == .milliseconds(320))
    }

    @Test func installSeedsTheAcceptedRegionImmediately() {
        let delegate = makeDelegate()
        #expect(delegate.acceptedRect == Self.closedRect)
    }

    @Test func growingIsDeferredUntilTheDrawCatchesUp() async {
        let delegate = makeDelegate()
        delegate.state.transition(to: .open(.shelf))

        // Right away the panel is still visibly a notch.
        #expect(delegate.acceptedRect == Self.closedRect)

        await settle(delegate)
        #expect(delegate.acceptedRect == Self.openRect)
    }

    @Test func shrinkingIsImmediate() async {
        let delegate = makeDelegate()
        delegate.state.transition(to: .open(.shelf))
        await settle(delegate)
        #expect(delegate.acceptedRect == Self.openRect)

        delegate.state.transition(to: .closed)
        // No await: a smaller region is always safe to accept at once.
        #expect(delegate.acceptedRect == Self.closedRect)
    }

    @Test func theHoverTrackerFollowsTheAcceptedRegionNotTheDrawnOne() async {
        let delegate = makeDelegate()
        delegate.state.transition(to: .open(.shelf))
        #expect(delegate.hoverView?.trackingRect == Self.closedRect)

        await settle(delegate)
        #expect(delegate.hoverView?.trackingRect == Self.openRect)
    }

    /// Closing again before the growth lands must not leave a pending task
    /// that expands a panel the user already dismissed.
    @Test func aTransitionDuringTheLagCancelsThePendingGrowth() async {
        let delegate = makeDelegate()
        delegate.state.transition(to: .open(.shelf))
        delegate.state.transition(to: .closed)

        await settle(delegate)
        #expect(delegate.acceptedRect == Self.closedRect)
    }

    /// Growing twice in a row must settle on the final region, not an
    /// intermediate one.
    @Test func rapidGrowthSettlesOnTheLastState() async {
        let delegate = makeDelegate()
        delegate.state.transition(to: .peek(.dragTarget))
        delegate.state.transition(to: .open(.shelf))

        await settle(delegate)
        #expect(delegate.acceptedRect == Self.openRect)
    }

    /// The point of the whole exercise: a click in the region the panel is
    /// still growing into must pass through, not be swallowed.
    @Test func clicksPassThroughTheRegionStillBeingGrownInto() async throws {
        let delegate = makeDelegate()
        let host = try #require(delegate.hostView)

        // Deep inside the open panel, far below the notch band.
        let insideOpenOnly = NSPoint(x: 300, y: 100)

        delegate.state.transition(to: .open(.shelf))
        // Still drawn as a notch, so this must not be captured yet.
        #expect(host.hitTest(insideOpenOnly) == nil)

        await settle(delegate)
        // Now the panel is really there.
        #expect(host.hitTest(insideOpenOnly) != nil)
    }

    /// `.receiving` is the one state that must widen at once.
    ///
    /// The lag exists so the app never accepts a click on something not
    /// yet drawn. During a drag there is no click to mis-accept, and the
    /// drop region is gated by hit-testing — so a third of a second of
    /// refused drops would land exactly when the cursor is moving into the
    /// panel it just opened.
    @Test func aDragWidensTheAcceptedRegionImmediately() {
        let delegate = makeDelegate()
        delegate.state.transition(to: .receiving)
        // No await: the drop area is available the moment the drag arrives.
        #expect(delegate.acceptedRect == Self.openRect)
    }

    /// The ambient now-playing badge is the second exemption, for the same
    /// reason.
    ///
    /// The lag exists so the app never accepts a click on something not yet
    /// drawn. The badge is drawn at once: `NotchRootView`'s spring is keyed
    /// on `app.state`, which does not change when playback starts, so the
    /// extra 34pt snaps in the moment the snapshot publishes. A lag here
    /// would be a dead zone rather than a margin — a visible badge deaf to
    /// clicks and hover for a third of a second.
    @Test func theBadgeWidensTheAcceptedRegionImmediately() {
        let delegate = makeDelegate()

        delegate.nowPlayingDidChange(Self.playing)
        // No await: the badge is already on screen.
        #expect(delegate.acceptedRect == Self.badgedRect)
        #expect(delegate.hoverView?.trackingRect == Self.badgedRect)
    }

    /// The same thing said in clicks, through the real hit test.
    @Test func aClickOnTheBadgeLandsWithoutWaitingForTheLag() throws {
        let delegate = makeDelegate()
        let host = try #require(delegate.hostView)

        // Mid-strip: past the notch's trailing edge at x 425, inside the
        // badge, level with the notch band.
        let onBadge = NSPoint(x: 440, y: 240)
        #expect(host.hitTest(onBadge) == nil)

        delegate.nowPlayingDidChange(Self.playing)
        #expect(host.hitTest(onBadge) != nil)
    }

    /// And the exemption is scoped to the badge, not handed to everything
    /// that happens while music plays: opening the panel still springs, so
    /// it still lags.
    @Test func aClickOpenedPanelStillLagsWhileMusicPlays() async {
        let delegate = makeDelegate()
        delegate.nowPlayingDidChange(Self.playing)
        #expect(delegate.acceptedRect == Self.badgedRect)

        delegate.state.transition(to: .open(.shelf))
        #expect(delegate.acceptedRect == Self.badgedRect)

        await settle(delegate)
        #expect(delegate.acceptedRect == Self.openRect)
    }

    /// And the exception is only for `.receiving`.
    @Test func aClickOpenedPanelStillLags() {
        let delegate = makeDelegate()
        delegate.state.transition(to: .open(.shelf))
        #expect(delegate.acceptedRect == Self.closedRect)
    }

    /// The invariant itself, stated directly.
    @Test func theAcceptedRegionIsNeverLargerThanTheDrawnOne() async {
        let delegate = makeDelegate()
        for next in [NotchState.peek(.dragTarget), .open(.shelf), .closed, .receiving] {
            delegate.state.transition(to: next)
            let drawn = NotchShape.visibleRect(
                presentation: next.presentation,
                anchor: delegate.currentAnchor,
                panelFrame: delegate.currentFrame
            )
            let accepted = delegate.acceptedRect
            #expect(accepted.width * accepted.height <= drawn.width * drawn.height)
        }
    }
}
