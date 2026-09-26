import Foundation
import Testing
@testable import CreativeNotchCore

/// Withdrawing a peek whose module has just been switched off.
///
/// Toggles take effect immediately, so a peek already in the slot has to be
/// *withdrawn* rather than waited out. A 3s power peek surviving its own
/// module's disable is small, visible, and exactly the kind of thing that
/// makes a preference feel unreliable.
///
/// Modelled on `dismissTimerDone`, which is the same verb for the timer.
struct PeekWithdrawalTests {

    private let now: TimeInterval = 100

    private func track() -> TrackSnapshot {
        TrackSnapshot(title: "T", artist: "A", isPlaying: true)
    }

    @Test func clearingPowerWithdrawsItsPeek() {
        var arbiter = PeekArbiter()
        arbiter.recordPower(.pluggedIn(level: 80), now: now)
        #expect(arbiter.content(now: now) != nil)

        arbiter.clearPower()

        #expect(arbiter.content(now: now) == nil)
    }

    /// Each verb withdraws its own module's peek and nothing else. A clear
    /// that blanked the whole arbiter would pass the two tests above while
    /// silently cancelling another module's interruption.
    @Test func clearingOneModulesPeekLeavesTheOthers() {
        let done = TimerCompletion(duration: 60, lateness: 0)
        var arbiter = PeekArbiter()
        arbiter.recordPower(.pluggedIn(level: 80), now: now)
        arbiter.recordTimerFinished(done, now: now)

        arbiter.clearPower()
        #expect(arbiter.content(now: now) == .timerDone(done),
                "clearing power withdrew the finished-timer peek")

        arbiter.recordPower(.pluggedIn(level: 80), now: now)
        arbiter.dismissTimerDone()
        #expect(arbiter.content(now: now) == .power(.pluggedIn(level: 80)),
                "dismissing the timer withdrew the power peek")
    }

    /// Withdrawing reveals whatever was queued behind it rather than blanking
    /// the slot -- which is the whole reason the arbiter is a priority list
    /// and not a single value.
    @Test func clearingPowerRevealsWhatWasBehindIt() {
        var arbiter = PeekArbiter()
        arbiter.setNowPlaying(track())
        arbiter.recordPower(.pluggedIn(level: 80), now: now)
        #expect(arbiter.content(now: now) == .power(.pluggedIn(level: 80)))

        arbiter.clearPower()

        #expect(arbiter.content(now: now) == .nowPlaying(track()))
    }

    /// Withdrawal is not expiry: a cleared peek must not come back when the
    /// clock has not yet passed its TTL.
    @Test func aWithdrawnPeekDoesNotReturnBeforeItsTTL() {
        var arbiter = PeekArbiter()
        arbiter.recordPower(.pluggedIn(level: 80), now: now)
        arbiter.clearPower()

        #expect(arbiter.content(now: now + PeekArbiter.powerTTL / 2) == nil)
    }

    /// And the verbs are idempotent, so a switchboard that clears on every
    /// re-derivation does not have to ask first.
    @Test func clearingTwiceIsHarmless() {
        var arbiter = PeekArbiter()
        arbiter.recordPower(.pluggedIn(level: 80), now: now)
        arbiter.clearPower()
        arbiter.clearPower()

        #expect(arbiter.content(now: now) == nil)
    }
}
