import Foundation
import Testing
@testable import CreativeNotchCore

struct TimerPeekArbitrationTests {
    private let t0: TimeInterval = 1000
    private let done = TimerCompletion(duration: 1500, lateness: 0)
    private let track = TrackSnapshot(title: "T", artist: "A", isPlaying: true)

    @Test func aFinishedTimerPeeks() {
        var a = PeekArbiter()
        a.recordTimerFinished(done, now: t0)
        #expect(a.content(now: t0) == .timerDone(done))
    }

    /// Above the HUD: you explicitly asked to be interrupted by this.
    @Test func aFinishedTimerOutranksTheHUD() {
        var a = PeekArbiter()
        a.recordHUD(HUDEvent(kind: .volume(0.5)), now: t0)
        a.recordTimerFinished(done, now: t0)
        #expect(a.content(now: t0) == .timerDone(done))
    }

    @Test func aFinishedTimerOutranksNowPlaying() {
        var a = PeekArbiter()
        a.setNowPlaying(track)
        a.recordTimerFinished(done, now: t0)
        #expect(a.content(now: t0) == .timerDone(done))
    }

    /// Below drag: interrupting an in-flight drag would tear down the drop
    /// target mid-gesture.
    @Test func aDragStillOutranksAFinishedTimer() {
        var a = PeekArbiter()
        a.recordTimerFinished(done, now: t0)
        a.setDragActive(true)
        #expect(a.content(now: t0) == .dragTarget)
    }

    /// The safety expiry. Without it an unattended completion holds the
    /// peek forever and silently blocks HUD and now-playing peeks behind
    /// it -- volume feedback would just stop working.
    @Test func anUnacknowledgedCompletionExpiresAndUnblocksTheOthers() {
        var a = PeekArbiter()
        a.setNowPlaying(track)
        a.recordTimerFinished(done, now: t0)
        let after = t0 + PeekArbiter.timerDoneTTL + 1
        #expect(a.content(now: after) == .nowPlaying(track))
    }

    @Test func theCompletionSurvivesUpToItsExpiry() {
        var a = PeekArbiter()
        a.recordTimerFinished(done, now: t0)
        #expect(a.content(now: t0 + PeekArbiter.timerDoneTTL - 1) == .timerDone(done))
    }

    @Test func dismissingClearsItImmediately() {
        var a = PeekArbiter()
        a.recordTimerFinished(done, now: t0)
        a.dismissTimerDone()
        #expect(a.content(now: t0) == nil)
    }

    @Test func theExpiryIsLongEnoughToBeSeenAndShortEnoughNotToWedge() {
        #expect(PeekArbiter.timerDoneTTL >= 300)
        #expect(PeekArbiter.timerDoneTTL <= 1800)
    }
}
