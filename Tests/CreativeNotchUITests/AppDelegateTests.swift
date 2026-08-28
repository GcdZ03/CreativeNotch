import AppKit
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// The hover tracking rect is *derived* from `NotchState`: it must always
/// describe the region currently drawn, or `NSTrackingArea` reports
/// enter/exit for a shape that is no longer on screen. Before the funnel,
/// re-syncing it was a hand-written call at four sites and the tap gesture
/// hit none of them.
///
/// These tests drive the real `AppDelegate` -- which is why it had to move
/// out of the executable target, where no test could reach it -- against a
/// synthetic notched screen deliberately placed away from the global
/// origin.
///
/// Screen (1470, 200, 1470, 956) with a 38pt notch inset and 620pt
/// auxiliary areas gives anchor (2090, 1118, 230, 38) inside panel
/// (1895, 896, 620, 260), i.e. panel-local closed rect (195, 222, 230, 38).
@MainActor
struct AppDelegateStateFunnelTests {

    private static let notched = ScreenMetrics(
        frame: CGRect(x: 1470, y: 200, width: 1470, height: 956),
        safeAreaTopInset: 38,
        auxiliaryTopLeftWidth: 620,
        auxiliaryTopRightWidth: 620,
        menuBarHeight: 38
    )

    /// A second display the panel can be moved to, to exercise
    /// repositioning.
    private static let external = ScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
        safeAreaTopInset: 0,
        auxiliaryTopLeftWidth: 0,
        auxiliaryTopRightWidth: 0,
        menuBarHeight: 24
    )

    private func makeDelegate() -> AppDelegate {
        let delegate = AppDelegate()
        // These tests are about the funnel, not the expand animation, so
        // the growth lag is switched off. F6 has its own suite.
        delegate.growthDelay = .zero
        delegate.install(metrics: Self.notched)
        return delegate
    }

    /// What the tracking rect must be for `state`, derived independently
    /// of the delegate's own code path.
    private func expected(_ state: NotchState, on delegate: AppDelegate) -> CGRect {
        NotchShape.visibleRect(
            presentation: state.presentation,
            anchor: delegate.currentAnchor,
            panelFrame: delegate.currentFrame
        )
    }

    // MARK: - The funnel

    @Test func installSeedsTheTrackingRectFromTheClosedShape() {
        let delegate = makeDelegate()
        #expect(delegate.currentAnchor == .notch(CGRect(x: 2090, y: 1118, width: 230, height: 38)))
        #expect(delegate.currentFrame == CGRect(x: 1895, y: 896, width: 620, height: 260))
        #expect(delegate.hoverView?.trackingRect == CGRect(x: 195, y: 222, width: 230, height: 38))
    }

    /// The core guarantee: *any* programmatic transition, in any order,
    /// leaves the tracking rect matching that state's visible rect.
    @Test func everyProgrammaticTransitionResyncsTheTrackingRect() {
        let delegate = makeDelegate()
        let sequence: [NotchState] = [
            .peek(.nowPlaying(TrackSnapshot(title: "t", artist: "a", isPlaying: true))),
            .open(.shelf),
            .receiving,
            .open(.clipboard),
            .peek(.dragTarget),
            .closed,
            .receiving,
            .closed,
        ]
        for next in sequence {
            delegate.state.transition(to: next)
            #expect(delegate.state.state == next)
            #expect(
                delegate.hoverView?.trackingRect == expected(next, on: delegate),
                "tracking rect is stale after transitioning to \(next)"
            )
        }
    }

    /// The same guarantee pinned to literal numbers, so a `visibleRect`
    /// that stopped depending on the presentation could not satisfy both
    /// this and the closed-state seed above.
    @Test func peekWidensTheTrackingRectAndExpandedTakesTheWholePanel() {
        let delegate = makeDelegate()

        delegate.state.transition(to: .peek(.dragTarget))
        // 320x44, centred on the notch, top-aligned: local midX 310.
        #expect(delegate.hoverView?.trackingRect == CGRect(x: 150, y: 216, width: 320, height: 44))

        delegate.state.transition(to: .receiving)
        #expect(delegate.hoverView?.trackingRect == CGRect(x: 0, y: 0, width: 620, height: 260))

        delegate.state.transition(to: .closed)
        #expect(delegate.hoverView?.trackingRect == CGRect(x: 195, y: 222, width: 230, height: 38))
    }

    // MARK: - Mouse exit (M1)

    /// The dwell shows whatever the arbiter has. An empty arbiter has
    /// nothing, so record a HUD event first — which is also the real
    /// sequence: a level changes, then the notch shows it.
    @Test func theDwellPeeksThroughTheFunnel() {
        let delegate = makeDelegate()
        delegate.showHUD(.volume(0.5))

        // Close, then dwell — so the assertion runs through the real
        // peek() -> arbiter.content(now:) path rather than showHUD's
        // direct transition. Without this, gutting peek() passes.
        delegate.state.transition(to: .closed)
        delegate.hoverView?.onDwell()

        #expect(delegate.state.state.presentation == .peek)
        #expect(delegate.hoverView?.trackingRect == CGRect(x: 150, y: 216, width: 320, height: 44))
    }

    @Test func aMouseExitEndsAHoverPeek() {
        let delegate = makeDelegate()
        delegate.state.transition(to: .peek(.dragTarget))
        delegate.hoverView?.onExit()
        #expect(delegate.state.state == .closed)
        #expect(delegate.hoverView?.trackingRect == CGRect(x: 195, y: 222, width: 230, height: 38))
    }

    @Test func aMouseExitDoesNotCloseAClickOpenedPanelImmediately() {
        let delegate = makeDelegate()
        delegate.state.transition(to: .open(.shelf))
        delegate.hoverView?.onExit()
        #expect(delegate.state.state == .open(.shelf))
    }

    /// The bug the funnel and the explicit `switch` exist to prevent: a
    /// drag that moves below the notch must not close the drop target it
    /// is aimed at.
    @Test func aMouseExitDuringADragKeepsTheDropTargetAlive() {
        let delegate = makeDelegate()
        delegate.state.transition(to: .receiving)
        delegate.hoverView?.onExit()
        #expect(delegate.state.state == .receiving)
        #expect(delegate.hoverView?.trackingRect == CGRect(x: 0, y: 0, width: 620, height: 260))
    }

    @Test func aMouseExitWhileClosedChangesNothing() {
        let delegate = makeDelegate()
        delegate.hoverView?.onExit()
        #expect(delegate.state.state == .closed)
    }

    // MARK: - Re-installing (F1)

    /// `install` builds a *fresh* panel and hover tracker, so it must
    /// position them whether or not the geometry changed.
    ///
    /// It used to delegate to `reposition`, which dedupes on unchanged
    /// geometry — correct for a screen change, wrong here. A second install
    /// left the new panel at the origin and the tracking rect empty, which
    /// means no tracking area at all and hover silently dead.
    @Test func reinstallingOnTheSameScreenStillPositionsTheNewPanel() {
        let delegate = makeDelegate()
        delegate.install(metrics: Self.notched)     // same metrics, second time

        #expect(delegate.hoverView?.trackingRect == CGRect(x: 195, y: 222, width: 230, height: 38))
        #expect(delegate.panel?.frame == CGRect(x: 1895, y: 896, width: 620, height: 260))
    }

    /// And it must not stack a second observer on the state, or every
    /// derived value would be re-synced twice per change.
    @Test func reinstallingDoesNotStackStateObservers() {
        let delegate = makeDelegate()
        #expect(delegate.stateObserverCount == 1)

        delegate.install(metrics: Self.notched)
        delegate.install(metrics: Self.notched)

        #expect(delegate.stateObserverCount == 1)
    }

    /// F3: each token has to go back to the centre that issued it.
    /// Removing from the wrong one is a silent no-op, so the leak this
    /// prevents would never announce itself.
    @Test func eachScreenObserverRemembersItsOwnNotificationCentre() {
        let delegate = AppDelegate()
        delegate.install(metrics: Self.notched)
        delegate.observeScreenChanges()

        let centers = delegate.screenObserverCenters
        #expect(centers.count == 2)
        #expect(centers[0] === NotificationCenter.default)
        #expect(centers[1] === NSWorkspace.shared.notificationCenter)
        #expect(centers[1] !== NotificationCenter.default)
    }

    /// Note the limit: that removal uses the *right* centre cannot be
    /// asserted. `removeObserver` on a centre that never issued the token
    /// is a silent no-op with no observable effect, which is precisely why
    /// the mismatch went unnoticed. The pairing above is the testable half.
    @Test func terminatingClearsTheScreenObservers() {
        let delegate = AppDelegate()
        delegate.install(metrics: Self.notched)
        delegate.observeScreenChanges()
        #expect(delegate.screenObserverCenters.count == 2)

        delegate.applicationWillTerminate(Notification(name: .init("terminate")))
        #expect(delegate.screenObserverCenters.isEmpty)
    }

    // MARK: - Repositioning (M3)

    @Test func repositioningToTheSameScreenIsANoOp() {
        let delegate = makeDelegate()
        // Every Cmd-Tab reaches this path; nothing has moved, so nothing
        // may be reassigned or redrawn.
        #expect(delegate.reposition(metrics: Self.notched) == false)
    }

    @Test func repositioningToADifferentScreenMovesThePanel() {
        let delegate = makeDelegate()
        #expect(delegate.reposition(metrics: Self.external) == true)
        #expect(delegate.currentAnchor.isNotch == false)
        #expect(delegate.currentAnchor == delegate.state.anchor)
        #expect(delegate.hoverView?.trackingRect == expected(.closed, on: delegate))
    }
}

/// `presentPeek` is the single owner of the `.peek` state: `showHUD` and
/// the hover dwell both route through it. It must refuse to override a
/// deliberate user state (`.open`, `.receiving`), and the HUD's transient
/// occupancy of the peek slot must actually expire and fall back, per
/// spec §5 -- nothing re-read the arbiter after the initial transition
/// before this.
@MainActor
struct HUDPeekOwnershipTests {

    private static let notched = ScreenMetrics(
        frame: CGRect(x: 1470, y: 200, width: 1470, height: 956),
        safeAreaTopInset: 38,
        auxiliaryTopLeftWidth: 620,
        auxiliaryTopRightWidth: 620,
        menuBarHeight: 38
    )

    /// A settable clock, so a test can jump "1.7 seconds later" without
    /// waiting for one -- the TTL re-check task itself still runs for
    /// real, on a short overridden delay, and is awaited rather than
    /// slept past.
    final class FakeClock {
        var value: TimeInterval
        init(_ value: TimeInterval) { self.value = value }
    }

    private func makeDelegate(clock: FakeClock) -> AppDelegate {
        let delegate = AppDelegate()
        delegate.growthDelay = .zero
        delegate.now = { clock.value }
        delegate.install(metrics: Self.notched)
        return delegate
    }

    // MARK: - C1: the peek expires and falls back

    @Test func aHUDPeekExpiresAndFallsBackToClosed() async {
        let clock = FakeClock(1_000)
        let delegate = makeDelegate(clock: clock)
        delegate.hudTTLDelay = .milliseconds(5)

        delegate.showHUD(.volume(0.5))
        #expect(delegate.state.state == .peek(.hud(HUDEvent(kind: .volume(0.5)))))

        clock.value += 1.7   // past the 1.5s TTL
        await delegate.hudTTLTask?.value

        #expect(delegate.state.state == .closed)
    }

    @Test func aHUDPeekThatHasNotExpiredYetSurvivesReevaluation() async {
        let clock = FakeClock(1_000)
        let delegate = makeDelegate(clock: clock)
        delegate.hudTTLDelay = .milliseconds(5)

        delegate.showHUD(.volume(0.5))
        clock.value += 0.2   // well inside the 1.5s TTL
        await delegate.hudTTLTask?.value

        #expect(delegate.state.state == .peek(.hud(HUDEvent(kind: .volume(0.5)))))
    }

    // MARK: - C2: showHUD must not transition from any state

    @Test func aHUDEventDoesNotOverrideReceiving() {
        let clock = FakeClock(1_000)
        let delegate = makeDelegate(clock: clock)
        delegate.state.transition(to: .receiving)

        delegate.showHUD(.volume(0.5))

        #expect(delegate.state.state == .receiving)
    }

    @Test func aHUDEventDoesNotOverrideOpen() {
        let clock = FakeClock(1_000)
        let delegate = makeDelegate(clock: clock)
        delegate.state.transition(to: .open(.shelf))

        delegate.showHUD(.volume(0.5))

        #expect(delegate.state.state == .open(.shelf))
    }

    @Test func aHUDEventStillUpdatesAnAlreadyShowingPeek() {
        // `.peek` is not a deliberate user state the way `.open` and
        // `.receiving` are -- a second HUD event while one is already
        // showing must still update the pill.
        let clock = FakeClock(1_000)
        let delegate = makeDelegate(clock: clock)
        delegate.showHUD(.volume(0.5))
        delegate.showHUD(.volume(0.6))
        #expect(delegate.state.state == .peek(.hud(HUDEvent(kind: .volume(0.6)))))
    }

    // MARK: - C3: the drag is wired into the arbiter

    /// `container.onDragEntered` sets `.receiving` directly, which already
    /// refuses a HUD event on its own (C2). This test isolates the
    /// *arbiter's* half of the wiring: force the state back to `.closed`
    /// without going through `onDragExited`, so `dragActive` is still true
    /// only inside the arbiter, then dwell -- the arbiter, not the state
    /// guard, must be what keeps the drag on top.
    @Test func dragOutranksAHUDEventThroughTheArbiter() throws {
        let clock = FakeClock(1_000)
        let delegate = makeDelegate(clock: clock)
        let container = try #require(delegate.panel?.contentView as? PassthroughContainer)

        delegate.showHUD(.volume(0.5))
        container.onDragEntered()
        delegate.state.transition(to: .closed)
        delegate.hoverView?.onDwell()

        #expect(delegate.state.state == .peek(.dragTarget))
    }

    /// The mirror image: once the drag actually ends, the arbiter must
    /// stop reporting it, or a drop that completes would leave `.dragTarget`
    /// permanently wedged into the peek slot's priority.
    @Test func endingTheDragStopsItOutrankingTheHUD() throws {
        let clock = FakeClock(1_000)
        let delegate = makeDelegate(clock: clock)
        let container = try #require(delegate.panel?.contentView as? PassthroughContainer)

        delegate.showHUD(.volume(0.5))
        container.onDragEntered()
        container.onDragExited()
        delegate.hoverView?.onDwell()

        #expect(delegate.state.state == .peek(.hud(HUDEvent(kind: .volume(0.5)))))
    }
}

/// The funnel itself, independent of AppKit.
@MainActor
struct AppStateTransitionTests {

    @Test func onlyAcceptedChangesNotifyTheObserver() {
        let state = AppState()
        var seen: [NotchState] = []
        state.observe { if case .state(let next) = $0 { seen.append(next) } }

        state.transition(to: .open(.shelf))
        state.transition(to: .open(.shelf))     // equal: dropped
        state.transition(to: .receiving)
        state.transition(to: .closed)

        #expect(seen == [.open(.shelf), .receiving, .closed])
        #expect(state.state == .closed)
    }

    @Test func aFreshStateIsClosedAndUnobserved() {
        #expect(AppState().state == .closed)
    }
}
