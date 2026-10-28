import AppKit
import SwiftUI
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// The motion changes from spec 2026-10-15, through the pure pieces they
/// lean on: which way a change moves, how far hover grows the drawing, and
/// the colour the equalizer takes from the artwork.
@MainActor
struct NotchMotionTests {

    private static let track = TrackSnapshot(title: "Song", artist: "Band", isPlaying: true)

    // MARK: - Direction picks the spring

    @Test func growingChangesAreMarkedAsGrowing() {
        let state = AppState()
        state.transition(to: .peek(.nowPlaying(Self.track)))
        #expect(state.lastChangeGrew)
        state.transition(to: .open(.shelf))
        #expect(state.lastChangeGrew)
    }

    @Test func shrinkingChangesAreNot() {
        let state = AppState()
        state.transition(to: .open(.shelf))
        state.transition(to: .peek(.nowPlaying(Self.track)))
        #expect(!state.lastChangeGrew)
        state.transition(to: .closed)
        #expect(!state.lastChangeGrew)
    }

    /// One peek replacing another is a swap, not a collapse, so it gets
    /// the opening spring rather than the snappy closing one.
    @Test func aPeekReplacingAPeekCountsAsGrowing() {
        let state = AppState()
        state.transition(to: .open(.shelf))
        state.transition(to: .peek(.power(.pluggedIn(level: 40))))
        state.transition(to: .peek(.dragTarget))
        #expect(state.lastChangeGrew)
    }

    /// The accepted region trails the drawn one by the growth delay, so the
    /// delay has to follow the spring that grows the shape.
    @Test func theGrowthDelayFollowsTheOpeningSpring() {
        #expect(AppDelegate.defaultGrowthDelay == .milliseconds(Int(NotchMotion.openResponse * 1000)))
    }

    /// How long the app treats a state's spring as still carrying the shape
    /// (2026-10-28, review of #81): at least as long as either spring takes
    /// to settle, or an anchor change near its end would morph from where it
    /// is going; and not much longer, or a change long after it would fade
    /// where it could morph. The springs are written out, as `open` and
    /// `close` define them.
    @Test func theSpringIsTreatedAsCarryingTheShapeUntilItSettles() {
        let open = Spring(response: NotchMotion.openResponse, dampingRatio: 0.74).settlingDuration
        let close = Spring(response: 0.26, dampingRatio: 1.0).settlingDuration
        #expect(open <= NotchMotion.springCarries)
        #expect(close <= NotchMotion.springCarries)
        #expect(NotchMotion.springCarries - open < 0.1)
    }

    // MARK: - Hover reacts at once, in the drawing only

    private static let closedDrawn = CGRect(x: 195, y: 0, width: 230, height: 38)

    @Test func hoveringTheClosedNotchGrowsTheDrawingDownAndOutward() {
        let r = NotchRootView.hoverInflated(Self.closedDrawn, isHovering: true, state: .closed)
        let g = NotchMotion.hoverGrowth
        #expect(r == CGRect(x: 195 - g.width / 2, y: 0, width: 230 + g.width, height: 38 + g.height))
    }

    @Test func notHoveringLeavesTheDrawingAlone() {
        #expect(NotchRootView.hoverInflated(Self.closedDrawn, isHovering: false, state: .closed)
                == Self.closedDrawn)
    }

    /// Once the notch has peeked or opened it is already larger, and a few
    /// more points on top would only make the next shape jump.
    @Test func onlyTheClosedNotchGrowsOnHover() {
        for state in [NotchState.peek(.nowPlaying(Self.track)), .open(.shelf), .receiving] {
            #expect(NotchRootView.hoverInflated(Self.closedDrawn, isHovering: true, state: state)
                    == Self.closedDrawn)
        }
    }

    /// Drawn only: the region that accepts clicks and hover never grows on
    /// hover, which keeps it no larger than what is drawn.
    @Test func hoverDoesNotTouchTheAcceptedRegion() {
        let delegate = NotchedDelegate.make()
        let before = delegate.acceptedRect
        delegate.hoverView?.onEnter()
        #expect(delegate.state.isHovering)
        #expect(delegate.acceptedRect == before)
        delegate.hoverView?.onExit()
        #expect(!delegate.state.isHovering)
    }

    // MARK: - The equalizer is legible on black

    /// Sampled once, where the artwork is set, so the closed notch and the
    /// peek share it and no render races an asynchronous sample.
    @Test func theBarTintFollowsTheArtwork() {
        let state = AppState()
        #expect(state.nowPlayingBarTint == nil)
        state.nowPlayingArtwork = SolidArtwork.red
        #expect(state.nowPlayingBarTint != nil)
        state.nowPlayingArtwork = nil
        #expect(state.nowPlayingBarTint == nil)
    }

    @Test func aDarkCoverStillGivesBrightBars() {
        let bars = ArtworkTint.legible(.black)
        var b: CGFloat = 0
        bars.usingColorSpace(.deviceRGB)!.getHue(nil, saturation: nil, brightness: &b, alpha: nil)
        #expect(b >= 0.8)
    }

    @Test func aVividCoverKeepsItsHue() {
        let bars = ArtworkTint.legible(NSColor(deviceRed: 0.6, green: 0, blue: 0, alpha: 1))
            .usingColorSpace(.deviceRGB)!
        #expect(bars.redComponent > bars.greenComponent + 0.2)
        #expect(bars.redComponent > bars.blueComponent + 0.2)
    }
}
