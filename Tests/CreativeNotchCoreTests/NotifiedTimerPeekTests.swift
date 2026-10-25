import Foundation
import Testing
@testable import CreativeNotchCore

/// A completion that already reached Notification Center peeks briefly
/// (2026-10-25).
///
/// Behind a full-screen app the banner told the user; the peek waiting for
/// them on the way back is a reminder, not the alert, so it shows for
/// `notifiedTimerDoneTTL` and goes. The clock starts when it is *shown*,
/// never at the finish: a stay longer than that in the full-screen app would
/// otherwise mean the peek never appeared at all.
struct NotifiedTimerPeekTests {
    private let t0: TimeInterval = 1000
    private let done = TimerCompletion(duration: 1500, lateness: 0)
    private let track = TrackSnapshot(title: "T", artist: "A", isPlaying: true)

    @Test func aNotifiedCompletionShownLateLastsBrieflyFromWhenItIsShown() {
        var a = PeekArbiter()
        a.recordTimerFinished(done, now: t0)
        a.timerDoneWasNotified(done)

        // A minute in the full-screen app: the peek is still waiting.
        let shown = t0 + 60
        #expect(a.content(now: shown) == .timerDone(done))
        a.timerDoneWasShown(now: shown)

        #expect(a.content(now: shown + PeekArbiter.notifiedTimerDoneTTL - 0.1) == .timerDone(done))
        #expect(a.content(now: shown + PeekArbiter.notifiedTimerDoneTTL) == nil)
        #expect(a.timerDoneIsBrief)
    }

    /// The slot returns to ambient content, as every other brief peek does.
    @Test func theBriefPeekFallsBackToWhatWasUnderneath() {
        var a = PeekArbiter()
        a.setNowPlaying(track)
        a.recordTimerFinished(done, now: t0)
        a.timerDoneWasNotified(done)
        a.timerDoneWasShown(now: t0 + 30)
        #expect(a.content(now: t0 + 30 + PeekArbiter.notifiedTimerDoneTTL + 1) == .nowPlaying(track))
    }

    /// Showing it again — a re-check re-applies the same peek — must not
    /// restart the clock, or the re-check loop would keep it forever.
    @Test func showingItAgainDoesNotRestartTheClock() {
        var a = PeekArbiter()
        a.recordTimerFinished(done, now: t0)
        a.timerDoneWasNotified(done)
        a.timerDoneWasShown(now: t0 + 10)
        a.timerDoneWasShown(now: t0 + 14)
        #expect(a.content(now: t0 + 10 + PeekArbiter.notifiedTimerDoneTTL) == nil)
    }

    /// Finished with the notch on screen: no banner, so the peek is the alert
    /// and keeps today's lifetime — until acknowledged or `timerDoneTTL`.
    @Test func anUnnotifiedCompletionKeepsTheLongLifetimeOnceShown() {
        var a = PeekArbiter()
        a.recordTimerFinished(done, now: t0)
        a.timerDoneWasShown(now: t0)
        #expect(a.content(now: t0 + PeekArbiter.timerDoneTTL - 1) == .timerDone(done))
        #expect(a.content(now: t0 + PeekArbiter.timerDoneTTL) == nil)
        #expect(a.timerDoneIsBrief == false)
    }

    /// Notified but not yet seen: nothing shortens it until it is on screen.
    @Test func aNotifiedCompletionWaitsUntilShown() {
        var a = PeekArbiter()
        a.recordTimerFinished(done, now: t0)
        a.timerDoneWasNotified(done)
        #expect(a.content(now: t0 + 300) == .timerDone(done))
        #expect(a.timerDoneIsBrief == false)
    }

    /// The backstop still holds: shown or not, notified or not, an
    /// unacknowledged completion cannot outlive `timerDoneTTL`. Being shown
    /// shortens a peek; it never lengthens one.
    @Test func showingNeverOutlivesTheBackstop() {
        var a = PeekArbiter()
        a.recordTimerFinished(done, now: t0)
        a.timerDoneWasNotified(done)
        a.timerDoneWasShown(now: t0 + PeekArbiter.timerDoneTTL - 2)
        #expect(a.content(now: t0 + PeekArbiter.timerDoneTTL) == nil)
    }

    /// A banner for an older completion says nothing about a newer one.
    @Test func aNoticeForAReplacedCompletionIsIgnored() {
        var a = PeekArbiter()
        let other = TimerCompletion(duration: 300, lateness: 0)
        a.recordTimerFinished(other, now: t0)
        a.recordTimerFinished(done, now: t0 + 1)
        a.timerDoneWasNotified(other)
        a.timerDoneWasShown(now: t0 + 2)
        #expect(a.content(now: t0 + 2 + PeekArbiter.notifiedTimerDoneTTL + 1) == .timerDone(done))
    }

    /// A new completion starts clean: neither a previous banner nor a
    /// previous showing carries over to it.
    @Test func aNewCompletionForgetsThePreviousOnesNoticeAndShowing() {
        var a = PeekArbiter()
        a.recordTimerFinished(done, now: t0)
        a.timerDoneWasNotified(done)
        a.timerDoneWasShown(now: t0)

        let next = TimerCompletion(duration: 300, lateness: 0)
        a.recordTimerFinished(next, now: t0 + 10)
        a.timerDoneWasShown(now: t0 + 10)
        #expect(a.content(now: t0 + 10 + PeekArbiter.notifiedTimerDoneTTL + 1) == .timerDone(next))
        #expect(a.timerDoneIsBrief == false)
    }

    /// Delivery confirmed after the peek was already on screen — the notch
    /// came back within the instant macOS took to answer. The user has the
    /// peek in front of them by then, so it keeps the long lifetime rather
    /// than vanishing on the strength of a banner that arrived second.
    @Test func aNoticeConfirmedAfterTheShowingChangesNothing() {
        var a = PeekArbiter()
        a.recordTimerFinished(done, now: t0)
        a.timerDoneWasShown(now: t0)
        a.timerDoneWasNotified(done)
        #expect(a.content(now: t0 + PeekArbiter.notifiedTimerDoneTTL + 1) == .timerDone(done))
    }

    /// Opening the panel still clears it at once.
    @Test func dismissingTheBriefPeekClearsItImmediately() {
        var a = PeekArbiter()
        a.recordTimerFinished(done, now: t0)
        a.timerDoneWasNotified(done)
        a.timerDoneWasShown(now: t0)
        a.dismissTimerDone()
        #expect(a.content(now: t0) == nil)
        #expect(a.timerDoneIsBrief == false)
    }

    /// Long enough to read "25m done" on the way back; short enough to be a
    /// reminder rather than a second alert.
    @Test func theBriefLifetimeIsAGlance() {
        #expect(PeekArbiter.notifiedTimerDoneTTL >= 3)
        #expect(PeekArbiter.notifiedTimerDoneTTL <= 10)
    }
}
