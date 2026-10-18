import AppKit
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// Two-finger swipes on the notch, through `AppDelegate.handleScroll`
/// (spec 2026-10-17). Real scroll events cannot be synthesised with phases
/// headlessly, so the delegate takes a `ScrollSample` and the hosting view
/// converts — a conversion too thin to need its own test.
@MainActor
struct TrackpadGestureTests {

    private static let track = TrackSnapshot(title: "Song", artist: "Band", isPlaying: true)

    /// The panel's top strip, level with the notch: y 222...260 in the
    /// 260pt test panel.
    private static let inTopStrip = CGPoint(x: 310, y: 245)
    /// Lower down, over the panel's content.
    private static let inContent = CGPoint(x: 120, y: 100)

    private func sample(_ phase: ScrollSample.Phase, dx: CGFloat = 0, dy: CGFloat = 0,
                        precise: Bool = true, momentum: Bool = false,
                        at location: CGPoint? = TrackpadGestureTests.inTopStrip) -> ScrollSample {
        ScrollSample(phase: phase, isMomentum: momentum, isPrecise: precise,
                     finger: CGVector(dx: dx, dy: dy), location: location)
    }

    /// One swipe, delivered as a begin, steps of `step`, and an end.
    @discardableResult
    private func swipe(_ d: AppDelegate, dx: CGFloat = 0, dy: CGFloat = 0, steps: Int = 4,
                       at location: CGPoint? = TrackpadGestureTests.inTopStrip) -> Bool {
        var consumed = d.handleScroll(sample(.began, at: location))
        for _ in 0..<steps {
            consumed = d.handleScroll(sample(.changed, dx: dx / CGFloat(steps), dy: dy / CGFloat(steps), at: location)) || consumed
        }
        d.handleScroll(sample(.ended, at: location))
        return consumed
    }

    private let far = NotchSwipe.commitDistance + 10

    // MARK: - Opening and closing

    @Test func pullingDownOpensThePanelOnItsLastTab() {
        let d = NotchedDelegate.make()
        swipe(d, dy: far)
        #expect(d.state.state == .open(d.state.lastOpenTab))
        #expect(d.state.pullProgress == 0)
    }

    @Test func aShortPullLeavesItClosedAndSpringsBack() {
        let d = NotchedDelegate.make()
        swipe(d, dy: NotchSwipe.commitDistance - 10)
        #expect(d.state.state == .closed)
        #expect(d.state.pullProgress == 0)
    }

    /// Mid-swipe, the shape follows the fingers.
    @Test func midSwipeThePullIsPublished() {
        let d = NotchedDelegate.make()
        d.handleScroll(sample(.began))
        d.handleScroll(sample(.changed, dy: NotchSwipe.commitDistance / 2))
        #expect(d.state.pullProgress == 0.5)
        d.handleScroll(sample(.cancelled))
        #expect(d.state.pullProgress == 0)
        #expect(d.state.state == .closed)
    }

    /// From the top strip — the tab icons, level with the notch — a push
    /// up closes the panel.
    @Test func pushingUpOnTheTopStripClosesTheOpenPanel() {
        let d = NotchedDelegate.make()
        d.state.transition(to: .open(.timer))
        swipe(d, dy: -far, at: Self.inTopStrip)
        #expect(d.state.state == .closed)
    }

    /// Over the content it is an ordinary scroll (2026-10-18). With natural
    /// scrolling, scrolling *down* is the fingers moving *up* — exactly the
    /// close gesture — so the panel used to vanish under a user scrolling
    /// toward the music controls.
    @Test func scrollingOverTheContentNeverClosesThePanel() {
        let d = NotchedDelegate.make()
        d.state.transition(to: .open(.timer))
        let consumed = swipe(d, dy: -far * 3, at: Self.inContent)
        #expect(d.state.state == .open(.timer))
        #expect(!consumed)
        #expect(d.state.pullProgress == 0)
    }

    /// An unknown position is treated as content: never close by guess.
    @Test func aSwipeWithNoPositionDoesNotClose() {
        let d = NotchedDelegate.make()
        d.state.transition(to: .open(.timer))
        swipe(d, dy: -far, at: nil)
        #expect(d.state.state == .open(.timer))
    }

    // MARK: - What it ignores

    /// A mouse wheel has no fingers to follow, and the scroll is passed on.
    @Test func aMouseWheelIsIgnoredAndPassedOn() {
        let d = NotchedDelegate.make()
        let consumed = d.handleScroll(sample(.changed, dy: 200, precise: false))
        #expect(!consumed)
        #expect(d.state.state == .closed)
    }

    /// Momentum after the fingers lift is the scroll coasting, not the user.
    @Test func momentumIsIgnored() {
        let d = NotchedDelegate.make()
        d.handleScroll(sample(.began))
        d.handleScroll(sample(.changed, dy: 10))
        d.handleScroll(sample(.ended))
        d.handleScroll(sample(.changed, dy: 200, momentum: true))
        #expect(d.state.state == .closed)
        #expect(d.state.pullProgress == 0)
    }

    /// In the open panel only a pull that would close is taken; anything
    /// else goes on to whatever scrolls there.
    @Test func theOpenPanelPassesOnScrollsItDoesNotUse() {
        let d = NotchedDelegate.make()
        d.state.transition(to: .open(.clipboard))
        #expect(!d.handleScroll(sample(.began)))
        #expect(!d.handleScroll(sample(.changed, dy: 20)))
    }

    @Test func aDragInFlightIsLeftAlone() {
        let d = NotchedDelegate.make()
        d.state.transition(to: .receiving)
        swipe(d, dy: -far)
        #expect(d.state.state == .receiving)
    }

    // MARK: - Skipping

    @Test func swipingLeftOnTheMusicPeekSkipsForward() {
        let d = NotchedDelegate.make()
        var sent: [MediaCommand] = []
        d.state.onMediaCommand = { sent.append($0) }
        d.state.showsMediaControls = true
        d.state.transition(to: .peek(.nowPlaying(Self.track)))

        swipe(d, dx: -(NotchSwipe.skipDistance + 10))
        swipe(d, dx: NotchSwipe.skipDistance + 10)

        #expect(sent == [.nextTrack, .previousTrack])
    }

    /// Without working transport controls there is nothing to skip with.
    @Test func noSkipWithoutMediaControls() {
        let d = NotchedDelegate.make()
        var sent: [MediaCommand] = []
        d.state.onMediaCommand = { sent.append($0) }
        d.state.showsMediaControls = false
        d.state.transition(to: .peek(.nowPlaying(Self.track)))

        swipe(d, dx: -(NotchSwipe.skipDistance + 10))

        #expect(sent.isEmpty)
    }

    // MARK: - Haptics

    /// One tap, where the pull commits — not a second one when the panel
    /// then opens.
    @Test func aCommittingPullTapsOnceInAll() {
        let d = NotchedDelegate.make()
        var taps = 0
        d.performHaptic = { taps += 1 }
        swipe(d, dy: far)
        #expect(d.state.state == .open(d.state.lastOpenTab))
        #expect(taps == 1)
    }

    /// Changing your mind after the tap leaves the next click-open its own.
    @Test func aCancelledPullDoesNotSwallowTheNextOpenTap() {
        let d = NotchedDelegate.make()
        var taps = 0
        d.performHaptic = { taps += 1 }
        d.handleScroll(sample(.began))
        d.handleScroll(sample(.changed, dy: far))
        d.handleScroll(sample(.changed, dy: -far))
        d.handleScroll(sample(.ended))
        #expect(taps == 1)

        d.state.transition(to: .open(.shelf))
        #expect(taps == 2)
    }

    // MARK: - Drawing the pull

    private static let closed = CGRect(x: 195, y: 0, width: 230, height: 38)
    private static let open = CGRect(x: 0, y: 0, width: 620, height: 260)

    @Test func noPullDrawsTheShapeAsItIs() {
        #expect(NotchRootView.pulled(Self.closed, opening: Self.open, closing: Self.closed,
                                     pull: 0, state: .closed) == Self.closed)
    }

    /// A pull grows the closed shape part of the way toward the panel —
    /// a promise of what releasing will do, not the panel itself.
    @Test func aPullGrowsTheShapeTowardThePanel() {
        let r = NotchRootView.pulled(Self.closed, opening: Self.open, closing: Self.closed,
                                     pull: 1, state: .closed)
        #expect(r.width > Self.closed.width && r.width < Self.open.width)
        #expect(r.height > Self.closed.height && r.height < Self.open.height)
        #expect(r.minY == 0)
    }

    @Test func aClosingPullShrinksTheOpenPanel() {
        let r = NotchRootView.pulled(Self.open, opening: Self.open, closing: Self.closed,
                                     pull: -1, state: .open(.shelf))
        #expect(r.width < Self.open.width && r.height < Self.open.height)
    }
}
