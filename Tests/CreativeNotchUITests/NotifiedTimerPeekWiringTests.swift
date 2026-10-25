import AppKit
import Foundation
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// A timer that finished behind a full-screen app, and was announced by a
/// banner, peeks briefly when the notch comes back (2026-10-25).
///
/// How long is `NotifiedTimerPeekTests`' (Core); this pins the connection:
/// that a delivered banner reaches the arbiter, that the brief clock starts
/// when the notch is back on screen rather than at the finish, and that the
/// re-check is scheduled for it. Every delay is zero and the clock is
/// injected, so nothing here sleeps.
@MainActor
struct NotifiedTimerPeekWiringTests {

    private final class Clock { var now: TimeInterval = 100 }

    private func makeDelegate(
        authorization: TimerNoticeAuthorization = .allowed
    ) -> (AppDelegate, SilentTimerNotices, Clock) {
        let delegate = NotchedDelegate.make()
        delegate.setPanelShown = { _ in }
        delegate.timerDoneTTLDelay = .zero
        delegate.notifiedTimerDoneTTLDelay = .zero
        let clock = Clock()
        delegate.now = { clock.now }
        let notices = SilentTimerNotices()
        notices.status = authorization
        delegate.timerNotices = notices
        return (delegate, notices, clock)
    }

    private func finished(_ duration: TimeInterval = 600) throws -> Countdown {
        try #require(Countdown(duration: duration, startingAt: Date().addingTimeInterval(-duration)))
    }

    private func isTimerPeek(_ state: NotchState) -> Bool {
        if case .peek(.timerDone) = state { return true }
        return false
    }

    @Test func aBannerMakesTheLatePeekBrief() async throws {
        let (delegate, notices, clock) = makeDelegate()
        delegate.applyFullScreen(true)
        delegate.timerDidFinish(try finished())
        #expect(notices.posted.count == 1)

        clock.now += 60
        delegate.applyFullScreen(false)
        #expect(isTimerPeek(delegate.state.state))
        #expect(delegate.arbiter.timerDoneIsBrief)

        clock.now += PeekArbiter.notifiedTimerDoneTTL + 1
        await delegate.peekTTLTask?.value
        #expect(delegate.state.state == .closed)
    }

    /// The seconds count from the notch coming back, not from the finish: a
    /// minute in the full-screen app must still leave a peek to see.
    @Test func theBriefClockStartsWhenTheNotchComesBack() async throws {
        let (delegate, _, clock) = makeDelegate()
        delegate.applyFullScreen(true)
        delegate.timerDidFinish(try finished())

        clock.now += 60
        delegate.applyFullScreen(false)
        clock.now += PeekArbiter.notifiedTimerDoneTTL - 1
        await delegate.peekTTLTask?.value
        #expect(isTimerPeek(delegate.state.state))

        clock.now += 2
        await delegate.peekTTLTask?.value
        #expect(delegate.state.state == .closed)
    }

    /// Still hidden, nothing is shown, so nothing is brief yet.
    @Test func whileHiddenThePeekIsNotYetBrief() throws {
        let (delegate, _, _) = makeDelegate()
        delegate.applyFullScreen(true)
        delegate.timerDidFinish(try finished())
        #expect(delegate.arbiter.timerDoneIsBrief == false)
    }

    /// No banner with the notch on screen, so the peek is the alert and keeps
    /// today's lifetime.
    @Test func aTimerFinishingOnScreenKeepsTheLongPeek() async throws {
        let (delegate, _, clock) = makeDelegate()
        delegate.timerDidFinish(try finished())

        clock.now += PeekArbiter.notifiedTimerDoneTTL + 1
        await delegate.peekTTLTask?.value
        #expect(isTimerPeek(delegate.state.state))
        #expect(delegate.arbiter.timerDoneIsBrief == false)
    }

    /// Denied, the banner went nowhere: the peek is the only thing the user
    /// will see, so it is not cut short.
    @Test func aDeniedBannerKeepsTheLongPeek() async throws {
        let (delegate, notices, clock) = makeDelegate(authorization: .denied)
        delegate.applyFullScreen(true)
        delegate.timerDidFinish(try finished())
        #expect(notices.posted.count == 1)

        clock.now += 60
        delegate.applyFullScreen(false)
        clock.now += PeekArbiter.notifiedTimerDoneTTL + 1
        await delegate.peekTTLTask?.value
        #expect(isTimerPeek(delegate.state.state))
    }

    /// Banners off: macOS accepts the notice and shows nothing, so the
    /// peek is still the only thing the user will see.
    @Test func bannersOffKeepTheLongPeek() async throws {
        let (delegate, notices, clock) = makeDelegate(authorization: .bannersOff)
        delegate.applyFullScreen(true)
        delegate.timerDidFinish(try finished())
        #expect(notices.posted.count == 1)

        clock.now += 60
        delegate.applyFullScreen(false)
        clock.now += PeekArbiter.notifiedTimerDoneTTL + 1
        await delegate.peekTTLTask?.value
        #expect(isTimerPeek(delegate.state.state))
    }

    @Test func notificationsSwitchedOffKeepTheLongPeek() async throws {
        let (delegate, notices, clock) = makeDelegate()
        delegate.state.onSetTimerNotifyWhenHidden?(false)
        delegate.applyFullScreen(true)
        delegate.timerDidFinish(try finished())
        #expect(notices.posted.isEmpty)

        clock.now += 60
        delegate.applyFullScreen(false)
        clock.now += PeekArbiter.notifiedTimerDoneTTL + 1
        await delegate.peekTTLTask?.value
        #expect(isTimerPeek(delegate.state.state))
    }

    /// Opening the panel is acknowledgement, brief or not.
    @Test func openingThePanelStillClearsTheBriefPeek() throws {
        let (delegate, _, clock) = makeDelegate()
        delegate.installOutsideClickMonitor = { _ in NSObject() }
        delegate.removeOutsideClickMonitor = { _ in }
        delegate.applyFullScreen(true)
        delegate.timerDidFinish(try finished())
        clock.now += 60
        delegate.applyFullScreen(false)

        delegate.state.transition(to: .open(.timer))

        #expect(delegate.arbiter.content(now: clock.now) == nil)
    }

    /// Which delay the brief peek is re-checked on, read rather than timed,
    /// for the reason `eachPeekIsRecheckedOnItsOwnTTL` gives: at zero delays
    /// the two cannot be told apart.
    @Test func aBriefTimerPeekIsRecheckedOnTheBriefDelay() {
        let done = PeekContent.timerDone(TimerCompletion(duration: 1500, lateness: 0))
        let long = Duration.milliseconds(33)
        let brief = Duration.milliseconds(44)

        #expect(AppDelegate.reevaluationDelay(
            for: done, power: .milliseconds(22), timerDone: long,
            timerDoneIsBrief: true, notifiedTimerDone: brief
        ) == brief)
        #expect(AppDelegate.reevaluationDelay(
            for: done, power: .milliseconds(22), timerDone: long,
            timerDoneIsBrief: false, notifiedTimerDone: brief
        ) == long)
    }

    @Test func theBriefDelayMirrorsTheArbiter() {
        #expect(AppDelegate.defaultNotifiedTimerDoneTTLDelay
            == .milliseconds(Int(PeekArbiter.notifiedTimerDoneTTL * 1000)))
    }
}
