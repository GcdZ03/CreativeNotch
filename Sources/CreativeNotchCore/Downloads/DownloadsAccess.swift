import Foundation

/// Whether the app may read the Downloads folder, as far as it has asked.
///
/// Three states rather than a `Bool`, for the reason `LaunchAtLoginState`
/// has `.unread`: "not asked yet" must not be mistaken for "refused", or the
/// Settings row would warn about a permission nobody has been asked for.
public enum DownloadsAccess: Equatable, Sendable {
    /// Not asked: the module is off, or the question is still on screen.
    case unknown
    case granted
    /// macOS refused — the person said no, or turned it off in System
    /// Settings — or the folder could not be read at all. Nothing is
    /// subscribed, and the Settings row says so rather than reading "on"
    /// over a module that cannot see anything.
    case denied

    /// The Settings row's line while denied, or `nil`.
    public var warning: String? {
        guard self == .denied else { return nil }
        return String(localized: "CreativeNotch can't read your Downloads folder, so it can't see downloads. Allow it in System Settings \u{203A} Privacy & Security \u{203A} Files & Folders, then reopen Settings or switch this off and on.", bundle: .creativeNotch)
    }
}
