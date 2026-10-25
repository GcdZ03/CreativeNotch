import AppKit
@preconcurrency import UserNotifications
import CreativeNotchCore

/// Where a finished timer's notification goes (2026-10-24).
///
/// A protocol rather than a closure like `playChime`, for two reasons: it has
/// three verbs that belong together, and `SandboxedSeamsTests` can then assert
/// *which* one a delegate holds -- a closure cannot be told apart from another.
@MainActor
protocol TimerNoticeCenter: AnyObject {
    /// Called when a countdown starts with the setting on. Asks macOS for
    /// permission if it has never been asked (`TimerDoneNotice
    /// .shouldRequestAuthorization`), and does nothing otherwise.
    func prepare()

    /// Shows the banner, or quietly does nothing if notifications are
    /// denied: the chime and VoiceOver have already said it.
    func post(_ notice: TimerDoneNotice)

    /// What macOS currently allows, for the line under the Settings switch --
    /// including whether banners are off (`.bannersOff`). Only reads; it
    /// never prompts.
    func authorization() async -> TimerNoticeAuthorization
}

/// The sandboxed default every `AppDelegate()` starts with, and the recorder
/// the tests read. Reaches nothing outside this object.
@MainActor
final class SilentTimerNotices: TimerNoticeCenter {
    private(set) var posted: [TimerDoneNotice] = []
    private(set) var prepareCount = 0
    var status: TimerNoticeAuthorization = .notDetermined

    func prepare() { prepareCount += 1 }
    func post(_ notice: TimerDoneNotice) { posted.append(notice) }
    func authorization() async -> TimerNoticeAuthorization { status }
}

/// The real thing, through `UNUserNotificationCenter`. Installed only by
/// `AppDelegate.configureForRealLaunch()`.
///
/// **Constructing it touches nothing.** The center is reached lazily, on the
/// first verb: `UNUserNotificationCenter.current()` traps in a process with
/// no bundle -- `swift test`, or the bare binary `swift run` builds -- and
/// `SandboxedSeamsTests` constructs one to check the launch configuration.
/// The bundle check below makes the unbundled binary a silent no-op instead.
///
/// Nothing is scheduled ahead: `post` adds a request with no trigger, which
/// delivers at once. See `TimerDoneNotice` for why a trigger date would be a
/// second deadline.
@MainActor
final class SystemTimerNotices: NSObject, TimerNoticeCenter, UNUserNotificationCenterDelegate {

    private var center: UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else {
            return nil
        }
        let center = UNUserNotificationCenter.current()
        // Set on every reach rather than once: it is a property assignment,
        // and it is what lets a banner show while Settings has this app
        // frontmost -- without a delegate, macOS drops it silently there.
        if center.delegate !== self { center.delegate = self }
        return center
    }

    func prepare() {
        guard let center else { return }
        Task { @MainActor in
            let status = Self.authorization(of: await center.notificationSettings())
            guard TimerDoneNotice.shouldRequestAuthorization(enabled: true, authorization: status) else { return }
            // Alerts only. The app plays its own chime, so asking for sound
            // would be asking for a permission it never uses.
            _ = try? await center.requestAuthorization(options: [.alert])
        }
    }

    func post(_ notice: TimerDoneNotice) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        let request = UNNotificationRequest(identifier: notice.identifier, content: content, trigger: nil)
        // Denied, this fails, and that is the whole of the denied path: the
        // chime and the announcement went out before this was called.
        center.add(request) { _ in }
    }

    func authorization() async -> TimerNoticeAuthorization {
        guard let center else { return .notDetermined }
        return Self.authorization(of: await center.notificationSettings())
    }

    private static func authorization(of settings: UNNotificationSettings) -> TimerNoticeAuthorization {
        switch settings.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied:        return .denied
        default:
            // Allowed with the alert style at None delivers every notice to
            // Notification Center and never as a banner -- over a full-screen
            // app, the same as nothing. Read only; nothing here prompts.
            return settings.alertStyle == .none ? .bannersOff : .allowed
        }
    }

    /// Show the banner even while this app is frontmost.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
