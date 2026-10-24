import Foundation

/// What prompted a check for updates (2026-10-24).
///
/// There is no timer among them, on purpose: the one rule
/// (`ARCHITECTURE.md`) allows no repeating work, and each of these is a
/// moment the app is already awake for some other reason.
public enum UpdateCheckTrigger: Equatable, Sendable, CaseIterable {
    /// The app finished launching and started its subsystems.
    case launch
    /// `SystemActivity` came back to `.active`: a wake, an unlock, a
    /// session switched back to.
    case wake
    /// The Settings window was shown.
    case settingsOpened
    /// "Check for Updates…" in the menu bar, or "Check Now" in Settings.
    case manual
}

/// Whether a trigger should ask GitHub now.
public enum UpdateCheckPolicy {
    /// How long a wake or a Settings open waits after the last successful
    /// check.
    public static let interval: TimeInterval = 24 * 60 * 60

    /// - A manual check always runs: it bypasses the toggle and the throttle,
    ///   which exist for checks nobody asked for.
    /// - With "Automatically check for updates" off, nothing else runs.
    /// - A launch runs once per process, so it needs no throttle — and an
    ///   unchanged release costs a 304.
    /// - A wake and a Settings open happen many times a day, so each asks at
    ///   most once per `interval`. A last check in the future means the clock
    ///   went back; waiting for it to catch up could mean never checking, so
    ///   that counts as stale.
    public static func shouldCheck(
        _ trigger: UpdateCheckTrigger, lastCheck: Date?, automatic: Bool, now: Date
    ) -> Bool {
        switch trigger {
        case .manual:
            return true
        case .launch:
            return automatic
        case .wake, .settingsOpened:
            guard automatic else { return false }
            guard let lastCheck, lastCheck <= now else { return true }
            return now.timeIntervalSince(lastCheck) >= interval
        }
    }
}

/// What the updater remembers between launches, in the preferences domain.
///
/// `lastCheck` is the last check that got an answer — a failure is not a
/// check, so being offline at one wake does not wait a day for the next.
/// `etag` and `release` travel together: the ETag says "unchanged since
/// this release", and is meaningless without it.
public struct UpdateRecord: Equatable, Sendable {
    public var lastCheck: Date?
    public var etag: String?
    public var release: Release?

    public init(lastCheck: Date? = nil, etag: String? = nil, release: Release? = nil) {
        self.lastCheck = lastCheck
        self.etag = etag
        self.release = release
    }

    /// The ETag to send, only alongside the release it describes. A 304
    /// carries no body, so a reply to an ETag sent without a cached release
    /// would say "unchanged" about nothing.
    public var conditionalETag: String? {
        guard release != nil, let etag, !etag.isEmpty else { return nil }
        return etag
    }

    /// The record after a check finishes at `now`.
    public func applying(_ result: UpdateCheckResult, at now: Date) -> UpdateRecord {
        switch result {
        case .fresh(let release, let etag):
            return UpdateRecord(lastCheck: now, etag: etag, release: release)
        case .notModified:
            return UpdateRecord(lastCheck: now, etag: etag, release: release)
        case .failed:
            return self
        }
    }

    /// The record from raw defaults values, by `PreferenceKeys.resolveEnabled`'s
    /// policy: a value of the wrong type reads as absent and is left in
    /// place. So does a release whose links `parse` would not have taken
    /// (`Release.isTrusted`) — and with it gone, its ETag is not sent.
    public static func resolve(lastCheck: Any?, etag: Any?, release: Any?) -> UpdateRecord {
        UpdateRecord(
            lastCheck: (lastCheck as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) },
            etag: etag as? String,
            release: (release as? Data)
                .flatMap { try? JSONDecoder().decode(Release.self, from: $0) }
                .flatMap { $0.isTrusted ? $0 : nil }
        )
    }
}
