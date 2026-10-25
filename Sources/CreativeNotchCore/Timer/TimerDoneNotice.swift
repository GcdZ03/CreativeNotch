import Foundation

/// Whether macOS lets this app post notifications, as far as the timer cares.
///
/// Four cases rather than `UNAuthorizationStatus`'s five: provisional and
/// ephemeral both deliver, and Core cannot name a UserNotifications type.
public enum TimerNoticeAuthorization: Equatable, Sendable {
    case notDetermined
    case denied
    case allowed
    /// Allowed, but with the alert style in System Settings › Notifications
    /// set to None (2026-10-25). Posting still succeeds -- every notice goes
    /// to Notification Center -- yet no banner ever shows, which over a
    /// full-screen app is the same as nothing. Found in hands-on testing:
    /// the code was right and the user saw nothing until the style was
    /// Banners. Folded in here rather than kept as a second value because it
    /// is one more answer to the question this type asks: will the user see
    /// the notice?
    case bannersOff
}

/// Why the Settings row should warn -- an orange note and a button to System
/// Settings › Notifications -- rather than just inform.
///
/// Both cases are "the switch reads on and cannot do what it says", and both
/// are fixed in the same pane, so the row treats them alike; they differ only
/// in the sentence (`TimerDoneNotice.settingsNote`).
public enum TimerNoticeSettingsWarning: Equatable, Sendable {
    case denied
    case bannersOff
}

/// The notification a finished timer posts when its peek cannot be seen
/// (2026-10-24).
///
/// **Only where the peek cannot be seen.** The notch is the timer's alert;
/// a banner is a second one. Over a full-screen app the panel is ordered out
/// (`FullScreenWatcher`), so the peek lands in an invisible window and only
/// the chime and VoiceOver say anything. That is the one gap this fills. With
/// the notch on screen the peek already says it, and the open panel or a drag
/// holding the slot is someone looking at the notch, so a banner as well would
/// be the same news twice.
///
/// No polling and nothing scheduled ahead: the notification is posted at the
/// moment the timer's own one-shot fires, never queued with a trigger date.
/// A queued notification would have to be cancelled on every pause, resume
/// and cancel -- a second copy of the deadline that could disagree with
/// `Countdown`, which is the only one.
public struct TimerDoneNotice: Equatable, Sendable {

    /// One identifier for every finish, so a second timer's banner replaces
    /// the first's in Notification Center instead of stacking beneath it.
    public let identifier = "timer.done"
    public let title: String
    public let body: String

    /// The body is the spoken completion ("25-minute timer finished 2 hours
    /// ago"), not the peek's compact "25m": a banner is read as a sentence,
    /// away from the notch that gives "25m" its meaning.
    public init(completion: TimerCompletion) {
        title = String(localized: "Timer done", bundle: .creativeNotch)
        body = TimerSpokenText.completion(completion)
    }

    /// The whole rule: hidden, and wanted.
    public static func shouldPost(notchOnScreen: Bool, enabled: Bool) -> Bool {
        enabled && !notchOnScreen
    }

    /// Whether to ask macOS for permission now -- called when a countdown
    /// starts.
    ///
    /// **When a countdown starts, not at launch and not at the finish.**
    /// Nothing is asked at launch (`docs/ARCHITECTURE.md`, Permissions). At
    /// the finish the prompt would arrive *instead of* the banner, over the
    /// full-screen app the user is busy in, about a timer that has already
    /// ended. Starting a timer is a deliberate act at the desktop, with the
    /// reason for the question in front of the user.
    public static func shouldRequestAuthorization(
        enabled: Bool, authorization: TimerNoticeAuthorization
    ) -> Bool {
        enabled && authorization == .notDetermined
    }

    /// The line under the Settings switch, or `nil` when there is nothing to
    /// add. Denied is not an error -- the chime and VoiceOver still carry the
    /// finish -- but a switch reading "on" that can do nothing would be a lie
    /// without it.
    public static func settingsNote(for authorization: TimerNoticeAuthorization, enabled: Bool) -> String? {
        guard enabled else { return nil }
        switch authorization {
        case .allowed:
            return nil
        case .notDetermined:
            return String(localized: "macOS asks whether CreativeNotch may notify you the first time you start a timer.", bundle: .creativeNotch)
        case .denied:
            return String(localized: "Notifications are off for CreativeNotch in System Settings, so a timer that finishes behind a full-screen app will only chime.", bundle: .creativeNotch)
        case .bannersOff:
            return String(localized: "Banners are off for CreativeNotch, so timer notifications only go to Notification Center.", bundle: .creativeNotch)
        }
    }

    /// Whether that line is a warning, and which: `nil` while the switch is
    /// off (nothing would be posted anyway), allowed, or undecided (macOS will
    /// ask in time, so the note only informs).
    public static func settingsWarning(
        for authorization: TimerNoticeAuthorization, enabled: Bool
    ) -> TimerNoticeSettingsWarning? {
        guard enabled else { return nil }
        switch authorization {
        case .allowed, .notDetermined: return nil
        case .denied:                  return .denied
        case .bannersOff:              return .bannersOff
        }
    }

    /// Whether a posted notice reached the user as a banner, which is what
    /// lets the late peek be brief. Accepted is not enough: with the alert
    /// style set to None macOS accepts the request and shows nothing
    /// (`.bannersOff`), and then the peek is still the only signal.
    public static func bannerWasSeen(
        accepted: Bool, authorization: TimerNoticeAuthorization
    ) -> Bool {
        accepted && authorization == .allowed
    }
}
