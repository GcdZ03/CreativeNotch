import AppKit
import Foundation
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// A finished timer reaches Notification Center only where the peek cannot
/// be seen (2026-10-24).
///
/// When to post is `TimerDoneNoticeTests`' (Core); this pins the connection:
/// that the delegate asks with the right inputs, hands the notice to its
/// seam, and never lets the notice replace the chime or the announcement.
/// Every delegate here keeps the sandboxed `SilentTimerNotices`, so nothing
/// reaches the real notification center.
@MainActor
struct TimerNoticeWiringTests {

    private func makeDelegate() -> (AppDelegate, SilentTimerNotices) {
        let delegate = NotchedDelegate.make()
        delegate.setPanelShown = { _ in }
        delegate.timerDoneTTLDelay = .zero
        let notices = SilentTimerNotices()
        delegate.timerNotices = notices
        return (delegate, notices)
    }

    private func finished(_ duration: TimeInterval = 600) throws -> Countdown {
        try #require(Countdown(duration: duration, startingAt: Date().addingTimeInterval(-duration)))
    }

    @Test func aTimerFinishingBehindAFullScreenAppPostsANotice() throws {
        let (delegate, notices) = makeDelegate()
        delegate.applyFullScreen(true)

        delegate.timerDidFinish(try finished())

        #expect(notices.posted.map(\.title) == ["Timer done"])
        #expect(notices.posted.map(\.body) == ["10-minute timer finished"])
    }

    /// On screen the peek says it. A banner as well would be twice.
    @Test func aTimerFinishingWithTheNotchOnScreenPostsNothing() throws {
        let (delegate, notices) = makeDelegate()
        delegate.timerDidFinish(try finished())
        #expect(notices.posted.isEmpty)

        // Back from full screen counts as on screen again.
        delegate.applyFullScreen(true)
        delegate.applyFullScreen(false)
        delegate.timerDidFinish(try finished())
        #expect(notices.posted.isEmpty)
    }

    @Test func switchedOffInSettingsPostsNothing() throws {
        let (delegate, notices) = makeDelegate()
        delegate.state.onSetTimerNotifyWhenHidden?(false)
        delegate.applyFullScreen(true)

        delegate.timerDidFinish(try finished())

        #expect(notices.posted.isEmpty)
    }

    /// The notice is added, never substituted: with notifications denied it
    /// posts nowhere, and the chime and VoiceOver are what is left.
    @Test func theChimeAndTheAnnouncementStillHappenBehindAFullScreenApp() throws {
        let (delegate, _) = makeDelegate()
        var chimes = 0
        var spoken: [String] = []
        delegate.playChime = { _ in chimes += 1 }
        delegate.announce = { spoken.append($0) }
        delegate.applyFullScreen(true)

        delegate.timerDidFinish(try finished())

        #expect(chimes == 1)
        #expect(spoken == ["10-minute timer finished"])
    }

    // MARK: - Asking for permission

    /// Starting a countdown is where permission is asked for -- the seam
    /// decides whether macOS has already been asked.
    @Test func startingACountdownPreparesNotices() {
        let (delegate, notices) = makeDelegate()
        delegate.state.onStartTimer?(300)
        delegate.state.onCancelTimer?()
        #expect(notices.prepareCount == 1)
    }

    @Test func startingACountdownWithNoticesOffAsksNothing() {
        let (delegate, notices) = makeDelegate()
        delegate.state.onSetTimerNotifyWhenHidden?(false)
        delegate.state.onStartTimer?(300)
        delegate.state.onCancelTimer?()
        #expect(notices.prepareCount == 0)
    }

    // MARK: - The setting

    @Test func theSettingIsLoadedSavedAndApplied() {
        let (delegate, _) = makeDelegate()
        #expect(delegate.state.timerNotifyWhenHidden == true)

        delegate.state.onSetTimerNotifyWhenHidden?(false)

        #expect(delegate.state.timerNotifyWhenHidden == false)
        #expect(PreferencesStore(defaults: delegate.preferencesDefaults).timerNotifyWhenHidden == false)
    }

    /// Settings shows what macOS answered, read when asked -- never polled.
    @Test func theAuthorizationIsReadBackForSettings() async {
        let (delegate, notices) = makeDelegate()
        notices.status = .denied
        await delegate.refreshTimerNoticeAuthorization()
        #expect(delegate.state.timerNoticeAuthorization == .denied)
    }

    /// The sandboxed default reaches nothing: a fresh delegate's notices are
    /// silent, and only the real launch points them at the system.
    @Test func aFreshDelegatesNoticesAreSilent() {
        let delegate = AppDelegate()
        #expect(delegate.timerNotices is SilentTimerNotices)
    }
}
