import Foundation

/// The three steps of "Update Now", in the order they run.
public enum UpdatePhase: Equatable, Sendable {
    /// The archive and its checksum, into a temporary folder.
    case downloading
    /// The checksum, then — once unpacked — the signature and the version.
    case verifying
    /// The swap at the running bundle's path.
    case installing
}

/// Why "Update Now" stopped. Every case leaves the running copy where it
/// was, except `restoreFailed`, which says where it went.
public enum UpdateInstallFailure: Error, Equatable, Sendable {
    case notInstallable
    case downloadFailed
    case checksumUnreadable
    case checksumMismatch
    case extractFailed
    case appMissing
    case signatureInvalid
    case versionMismatch(found: String?)
    case moveFailed
    case restoreFailed(backupPath: String)

    /// The sentence Settings shows after "Couldn't update:".
    public var reason: String {
        switch self {
        case .notInstallable:
            return String(localized: "This release has no download attached.", bundle: .creativeNotch)
        case .downloadFailed:
            return String(localized: "The download didn't finish. Check your connection and try again.", bundle: .creativeNotch)
        case .checksumUnreadable:
            return String(localized: "The release's checksum couldn't be read, so the download wasn't trusted.", bundle: .creativeNotch)
        case .checksumMismatch:
            return String(localized: "The download doesn't match the release's checksum, so it wasn't installed.", bundle: .creativeNotch)
        case .extractFailed:
            return String(localized: "The download couldn't be unpacked.", bundle: .creativeNotch)
        case .appMissing:
            return String(localized: "The download doesn't contain the app.", bundle: .creativeNotch)
        case .signatureInvalid:
            return String(localized: "The downloaded app's signature didn't verify, so it wasn't installed.", bundle: .creativeNotch)
        case .versionMismatch(let found?):
            return String(localized: "The downloaded app is version \(found), not the release's.", bundle: .creativeNotch)
        case .versionMismatch(nil):
            return String(localized: "The downloaded app doesn't say which version it is.", bundle: .creativeNotch)
        case .moveFailed:
            return String(localized: "The new copy couldn't be put in place. The current one is untouched.", bundle: .creativeNotch)
        case .restoreFailed(let path):
            return String(localized: "The new copy couldn't be put in place, and the previous one couldn't be moved back. It is at \(path).", bundle: .creativeNotch)
        }
    }
}

/// Everything the Settings "Updates" section can say (2026-10-24).
///
/// One value rather than a handful of flags, so "checking" and "installing"
/// can never both be true, and so the line under the version is a pure
/// function of it — testable here, with fixed dates, rather than in a
/// SwiftUI body.
///
/// A check — in flight, or failed and being reported — carries the update
/// already on offer, if any (2026-10-25), so asking again never hides it:
/// "Update to v…", "Update Now" and the release notes stay while the
/// answer is awaited, and stay through a failure to get one.
public enum UpdateStatus: Equatable, Sendable {
    case notChecked
    case checking(offer: Release?)
    case upToDate(checkedAt: Date)
    case available(Release)
    case checkFailed(UpdateCheckFailure, offer: Release?)
    case installing(Release, UpdatePhase)
    case installFailed(Release, UpdateInstallFailure)
    case relaunching(Release)

    /// The resting state a record implies: what Settings shows at launch,
    /// and what a quiet failure falls back to. A cached release that is not
    /// newer — the one just installed — reads as up to date.
    public static func settled(record: UpdateRecord, currentVersion: String) -> UpdateStatus {
        if let release = offer(record: record, currentVersion: currentVersion) {
            return .available(release)
        }
        if let lastCheck = record.lastCheck { return .upToDate(checkedAt: lastCheck) }
        return .notChecked
    }

    /// The newer release a record knows of, if any: what a check carries
    /// while it runs, and through its failure.
    public static func offer(record: UpdateRecord, currentVersion: String) -> Release? {
        UpdateAvailability.newer(record.release, than: currentVersion)
    }

    /// A check or an install is under way, so neither can start.
    public var isBusy: Bool {
        switch self {
        case .checking, .installing, .relaunching: return true
        case .notChecked, .upToDate, .available, .checkFailed, .installFailed: return false
        }
    }

    /// The newer release this status is about, if any — for the menu item
    /// and the "Release Notes" link.
    public var release: Release? {
        switch self {
        case .available(let release), .installing(let release, _),
             .installFailed(let release, _), .relaunching(let release):
            return release
        case .checking(let offer), .checkFailed(_, let offer):
            return offer
        case .notChecked, .upToDate:
            return nil
        }
    }

    /// The release "Update Now" would install: one on offer, offered again
    /// after a failed attempt, or still on offer through a check — and only
    /// with both of its assets. During a check the button stays, disabled
    /// by `isBusy`, rather than vanishing for the second the request takes.
    public var installableRelease: Release? {
        switch self {
        case .available(let release), .installFailed(let release, _):
            return release.isInstallable ? release : nil
        case .checking(let offer?), .checkFailed(_, let offer?):
            return offer.isInstallable ? offer : nil
        default:
            return nil
        }
    }

    /// The line under the version in Settings.
    ///
    /// The relative time is worked out when this is asked — when Settings
    /// draws — and is not kept fresh by anything, because keeping it fresh
    /// would take a timer. Opening Settings after a day checks again anyway.
    public func line(now: Date, locale: Locale = .autoupdatingCurrent) -> String {
        switch self {
        case .notChecked:
            return String(localized: "Not checked yet", bundle: .creativeNotch)
        case .checking:
            return String(localized: "Checking\u{2026}", bundle: .creativeNotch)
        case .upToDate(let checkedAt):
            let formatter = RelativeDateTimeFormatter()
            formatter.locale = locale
            formatter.dateTimeStyle = .named
            formatter.unitsStyle = .full
            // A check "in 5 minutes" means the clock went back; say now.
            let when = formatter.localizedString(for: min(checkedAt, now), relativeTo: now)
            return String(localized: "Up to date \u{2014} checked \(when)", bundle: .creativeNotch, comment: "When the last check ran: \"5 minutes ago\", \"yesterday\"")
        case .available(let release):
            let version = release.version?.description ?? release.tag
            return String(localized: "Version \(version) is available", bundle: .creativeNotch)
        case .checkFailed(.offline, _):
            return String(localized: "Couldn't check for updates. Check your connection and try again.", bundle: .creativeNotch)
        case .checkFailed(.rateLimited, _):
            return String(localized: "Couldn't check for updates: GitHub asked to wait. Try again later.", bundle: .creativeNotch)
        case .checkFailed(.unexpected, _):
            return String(localized: "Couldn't check for updates", bundle: .creativeNotch)
        case .installing(_, .downloading):
            return String(localized: "Downloading\u{2026}", bundle: .creativeNotch)
        case .installing(_, .verifying):
            return String(localized: "Verifying\u{2026}", bundle: .creativeNotch)
        case .installing(_, .installing):
            return String(localized: "Installing\u{2026}", bundle: .creativeNotch)
        case .installFailed(_, let failure):
            return String(localized: "Couldn't update: \(failure.reason)", bundle: .creativeNotch)
        case .relaunching:
            return String(localized: "Restarting\u{2026}", bundle: .creativeNotch)
        }
    }
}
