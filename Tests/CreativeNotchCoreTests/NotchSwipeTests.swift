import CoreGraphics
import Testing
@testable import CreativeNotchCore

/// Two-finger trackpad swipes on the notch (spec 2026-10-17): down to
/// open, up to close, sideways on the music peek to skip.
///
/// Distances are in *finger* space — positive y is the fingers moving down
/// the trackpad, positive x is them moving right — whatever the user's
/// scroll direction setting.
struct NotchSwipeTests {

    private func swipe(_ steps: [(CGFloat, CGFloat)]) -> NotchSwipe {
        var s = NotchSwipe()
        s.began()
        for (dx, dy) in steps { s.changed(fingerDX: dx, fingerDY: dy) }
        return s
    }

    private let far = NotchSwipe.commitDistance + 4

    // MARK: - Finger space

    /// With natural scrolling, fingers moving down scroll content down, so
    /// the event's delta is positive. Without it, the sign flips.
    @Test func fingerDirectionFollowsTheScrollSetting() {
        #expect(NotchSwipe.fingerDelta(deltaX: 3, deltaY: 5, invertedFromDevice: true) == CGVector(dx: 3, dy: 5))
        #expect(NotchSwipe.fingerDelta(deltaX: 3, deltaY: 5, invertedFromDevice: false) == CGVector(dx: -3, dy: -5))
    }

    // MARK: - Opening

    @Test func aLongEnoughPullDownOpensFromClosed() {
        #expect(swipe([(0, far)]).ended(on: .closed) == .open)
    }

    @Test func aPullDownAlsoOpensFromAPeek() {
        #expect(swipe([(0, far)]).ended(on: .peek) == .open)
        #expect(swipe([(0, far)]).ended(on: .mediaPeek) == .open)
    }

    @Test func aShortPullSpringsBack() {
        #expect(swipe([(0, NotchSwipe.commitDistance - 4)]).ended(on: .closed) == .none)
    }

    /// Pulling past the threshold and back again is changing your mind.
    @Test func pullingBackBelowTheThresholdCancels() {
        #expect(swipe([(0, far), (0, -20)]).ended(on: .closed) == .none)
    }

    /// Up on the closed notch or the music peek tucks the lyrics strip away,
    /// and the same push brings it back (2026-10-29). Whether there is a
    /// strip to toggle is the app's question, not the swipe's.
    @Test func pushingUpOnTheClosedNotchOrMusicPeekTogglesLyrics() {
        #expect(swipe([(0, -far)]).ended(on: .closed) == .toggleLyrics)
        #expect(swipe([(0, -far)]).ended(on: .mediaPeek) == .toggleLyrics)
    }

    @Test func pushingUpOnTheOtherPeeksDoesNothing() {
        #expect(swipe([(0, -far)]).ended(on: .peek) == .none)
        #expect(swipe([(0, -far)]).ended(on: .statusPeek) == .none)
    }

    @Test func aShortPushUpDoesNothing() {
        #expect(swipe([(0, -(NotchSwipe.commitDistance - 4))]).ended(on: .closed) == .none)
    }

    // MARK: - Closing

    @Test func aLongEnoughPushUpClosesTheOpenPanel() {
        #expect(swipe([(0, -far)]).ended(on: .expanded) == .close)
    }

    @Test func pullingDownOnTheOpenPanelDoesNothing() {
        #expect(swipe([(0, far)]).ended(on: .expanded) == .none)
    }

    // MARK: - Skipping

    /// As on an iPhone's player: fingers to the left is the next track.
    @Test func swipingLeftOnTheMusicPeekSkipsForward() {
        #expect(swipe([(-NotchSwipe.skipDistance - 4, 0)]).ended(on: .mediaPeek) == .nextTrack)
        #expect(swipe([(NotchSwipe.skipDistance + 4, 0)]).ended(on: .mediaPeek) == .previousTrack)
    }

    /// Only the music peek skips. The open panel's shelf scrolls sideways,
    /// and the closed notch gives no sign that a sideways swipe means music.
    @Test func swipingSidewaysElsewhereDoesNothing() {
        let left = swipe([(-NotchSwipe.skipDistance - 4, 0)])
        #expect(left.ended(on: .closed) == .none)
        #expect(left.ended(on: .peek) == .none)
        #expect(left.ended(on: .expanded) == .none)
    }

    // MARK: - One axis per swipe

    /// The first clear movement picks the axis, and the swipe keeps it: a
    /// sideways skip that drifts down must not open the panel.
    @Test func theFirstClearMovementLocksTheAxis() {
        let s = swipe([(-12, 1), (-NotchSwipe.skipDistance, far)])
        #expect(s.axis == .horizontal)
        #expect(s.ended(on: .mediaPeek) == .nextTrack)
    }

    @Test func tinyMovementsLeaveTheAxisOpen() {
        #expect(swipe([(2, 3)]).axis == .undecided)
    }

    @Test func aNewSwipeStartsFromNothing() {
        var s = swipe([(0, far)])
        s.began()
        #expect(s.ended(on: .closed) == .none)
        #expect(s.axis == .undecided)
    }

    // MARK: - Following the finger

    @Test func theOpenPullTracksTheFingerUpToTheThreshold() {
        #expect(swipe([(0, NotchSwipe.commitDistance / 2)]).pull(on: .closed) == 0.5)
        #expect(swipe([(0, NotchSwipe.commitDistance)]).pull(on: .closed) == 1)
    }

    /// Past the threshold it keeps giving, but less and less: a rubber band,
    /// not a wall and not a runaway.
    @Test func pastTheThresholdThePullRubberBands() {
        let a = swipe([(0, NotchSwipe.commitDistance * 2)]).pull(on: .closed)
        let b = swipe([(0, NotchSwipe.commitDistance * 4)]).pull(on: .closed)
        #expect(a > 1 && b > a)
        #expect(b - a < a - 1 + 0.5)
        #expect(b < 2)
    }

    /// The close pull is reported negative, toward smaller.
    @Test func theClosePullIsNegative() {
        #expect(swipe([(0, -NotchSwipe.commitDistance / 2)]).pull(on: .expanded) == -0.5)
    }

    /// A pull in the direction that does nothing is not shown at all.
    @Test func aPullThatWouldDoNothingIsNotDrawn() {
        #expect(swipe([(0, -20)]).pull(on: .closed) == 0)
        #expect(swipe([(0, 20)]).pull(on: .expanded) == 0)
        #expect(swipe([(-30, 0)]).pull(on: .closed) == 0)
    }

    @Test func crossingTheThresholdIsReportedOnce() {
        var s = NotchSwipe()
        s.began()
        let short = s.changed(fingerDX: 0, fingerDY: NotchSwipe.commitDistance - 1)
        let crossing = s.changed(fingerDX: 0, fingerDY: 2)
        let beyond = s.changed(fingerDX: 0, fingerDY: 5)
        #expect(!short)
        #expect(crossing)
        #expect(!beyond)
    }
}
