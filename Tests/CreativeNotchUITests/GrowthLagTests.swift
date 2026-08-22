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

    @Test func growingIsDeferredUntilTheDrawCatchesUp() async throws {
        let delegate = makeDelegate()
        delegate.state.transition(to: .open(.shelf))

        // Right away the panel is still visibly a notch.
        #expect(delegate.acceptedRect == Self.closedRect)

        try await Task.sleep(for: .milliseconds(150))
        #expect(delegate.acceptedRect == Self.openRect)
    }

    @Test func shrinkingIsImmediate() async throws {
        let delegate = makeDelegate()
        delegate.state.transition(to: .open(.shelf))
        try await Task.sleep(for: .milliseconds(150))
        #expect(delegate.acceptedRect == Self.openRect)

        delegate.state.transition(to: .closed)
        // No await: a smaller region is always safe to accept at once.
        #expect(delegate.acceptedRect == Self.closedRect)
    }

    @Test func theHoverTrackerFollowsTheAcceptedRegionNotTheDrawnOne() async throws {
        let delegate = makeDelegate()
        delegate.state.transition(to: .open(.shelf))
        #expect(delegate.hoverView?.trackingRect == Self.closedRect)

        try await Task.sleep(for: .milliseconds(150))
        #expect(delegate.hoverView?.trackingRect == Self.openRect)
    }

    /// Closing again before the growth lands must not leave a pending task
    /// that expands a panel the user already dismissed.
    @Test func aTransitionDuringTheLagCancelsThePendingGrowth() async throws {
        let delegate = makeDelegate()
        delegate.state.transition(to: .open(.shelf))
        delegate.state.transition(to: .closed)

        try await Task.sleep(for: .milliseconds(150))
        #expect(delegate.acceptedRect == Self.closedRect)
    }

    /// Growing twice in a row must settle on the final region, not an
    /// intermediate one.
    @Test func rapidGrowthSettlesOnTheLastState() async throws {
        let delegate = makeDelegate()
        delegate.state.transition(to: .peek(.dragTarget))
        delegate.state.transition(to: .open(.shelf))

        try await Task.sleep(for: .milliseconds(150))
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

        try await Task.sleep(for: .milliseconds(150))
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

    /// And the exception is only for `.receiving`.
    @Test func aClickOpenedPanelStillLags() {
        let delegate = makeDelegate()
        delegate.state.transition(to: .open(.shelf))
        #expect(delegate.acceptedRect == Self.closedRect)
    }

    /// The invariant itself, stated directly.
    @Test func theAcceptedRegionIsNeverLargerThanTheDrawnOne() async throws {
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
