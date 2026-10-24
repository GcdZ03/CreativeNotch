import Foundation
import Testing
@testable import CreativeNotchCore

/// When a finished timer also posts a notification, and what it says.
///
/// The rule is narrow on purpose: a notification is a second alert, so it is
/// posted only where the first one -- the peek -- cannot be seen. Everywhere
/// else the notch already says it, and a banner on top would say it twice.
struct TimerDoneNoticeTests {

    @Test func aNotchHiddenForAFullScreenAppPostsOne() {
        #expect(TimerDoneNotice.shouldPost(notchOnScreen: false, enabled: true))
    }

    /// The peek carries it. A banner as well would be the same news twice.
    @Test func aNotchOnScreenPostsNothing() {
        #expect(TimerDoneNotice.shouldPost(notchOnScreen: true, enabled: true) == false)
    }

    /// Switched off in Settings, the timer chimes and announces as it did
    /// before the setting existed.
    @Test func switchedOffPostsNothingEvenWhenHidden() {
        #expect(TimerDoneNotice.shouldPost(notchOnScreen: false, enabled: false) == false)
        #expect(TimerDoneNotice.shouldPost(notchOnScreen: true, enabled: false) == false)
    }

    @Test func itIsHeadedTimerDoneAndSaysWhichTimer() {
        let notice = TimerDoneNotice(completion: TimerCompletion(duration: 1500, lateness: 0))
        #expect(notice.title == "Timer done")
        #expect(notice.body == "25-minute timer finished")
    }

    /// A machine that slept through the deadline says how late it is, in the
    /// banner as on the peek: a stale event presented as current is the lie
    /// the completion text exists to avoid.
    @Test func aLateTimerSaysHowLate() {
        let notice = TimerDoneNotice(completion: TimerCompletion(duration: 600, lateness: 7200))
        #expect(notice.body == "10-minute timer finished 2 hours ago")
    }

    /// One identifier for every finish, so a second timer replaces the first
    /// one's banner in Notification Center instead of stacking under it.
    @Test func everyNoticeSharesOneIdentifier() {
        let a = TimerDoneNotice(completion: TimerCompletion(duration: 60, lateness: 0))
        let b = TimerDoneNotice(completion: TimerCompletion(duration: 600, lateness: 0))
        #expect(a.identifier == b.identifier)
        #expect(a.identifier == "timer.done")
    }

    // MARK: - Asking for permission

    /// Asked once, when a countdown starts -- never at launch, and never at
    /// the finish, where the prompt would take the banner's place.
    @Test func permissionIsAskedOnlyWhileUndecidedAndWanted() {
        #expect(TimerDoneNotice.shouldRequestAuthorization(enabled: true, authorization: .notDetermined))
        #expect(TimerDoneNotice.shouldRequestAuthorization(enabled: true, authorization: .allowed) == false)
        #expect(TimerDoneNotice.shouldRequestAuthorization(enabled: true, authorization: .denied) == false)
        #expect(TimerDoneNotice.shouldRequestAuthorization(enabled: false, authorization: .notDetermined) == false)
    }

    // MARK: - What Settings says

    /// Denied is not an error -- the chime and VoiceOver still carry it --
    /// but the switch would be a lie without saying so.
    @Test func deniedIsExplainedUnderTheSwitch() throws {
        let note = try #require(TimerDoneNotice.settingsNote(for: .denied, enabled: true))
        #expect(note.contains("System Settings"))
        #expect(note.contains("chime"))
    }

    @Test func undecidedSaysWhenItWillBeAsked() throws {
        let note = try #require(TimerDoneNotice.settingsNote(for: .notDetermined, enabled: true))
        #expect(note.contains("start"))
    }

    @Test func allowedOrSwitchedOffNeedsNoNote() {
        #expect(TimerDoneNotice.settingsNote(for: .allowed, enabled: true) == nil)
        #expect(TimerDoneNotice.settingsNote(for: .denied, enabled: false) == nil)
        #expect(TimerDoneNotice.settingsNote(for: .notDetermined, enabled: false) == nil)
    }
}
