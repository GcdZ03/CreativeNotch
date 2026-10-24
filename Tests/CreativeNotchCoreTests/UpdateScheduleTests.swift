import Foundation
import Testing
@testable import CreativeNotchCore

/// When the updater asks GitHub, what it remembers, and what Settings says
/// about it (2026-10-24). Every date is fixed: no test here reads a clock.
struct UpdateScheduleTests {

    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let hour: TimeInterval = 3_600

    // MARK: - Should it check now?

    /// The menu's "Check for Updates…" always asks — the toggle and the
    /// throttle are about checks nobody asked for.
    @Test func aManualCheckAlwaysRuns() {
        for automatic in [true, false] {
            for last in [nil, Self.now, Self.now.addingTimeInterval(-60)] as [Date?] {
                #expect(UpdateCheckPolicy.shouldCheck(.manual, lastCheck: last, automatic: automatic, now: Self.now))
            }
        }
    }

    /// Off, only the manual check runs.
    @Test(arguments: [UpdateCheckTrigger.launch, .wake, .settingsOpened])
    func automaticOffStopsEveryOtherTrigger(_ trigger: UpdateCheckTrigger) {
        #expect(!UpdateCheckPolicy.shouldCheck(trigger, lastCheck: nil, automatic: false, now: Self.now))
        #expect(!UpdateCheckPolicy.shouldCheck(trigger, lastCheck: Self.now.addingTimeInterval(-100 * Self.hour), automatic: false, now: Self.now))
    }

    /// A launch checks whenever the toggle is on: it happens once per run,
    /// and an unchanged release costs a 304.
    @Test func aLaunchChecksUnthrottled() {
        #expect(UpdateCheckPolicy.shouldCheck(.launch, lastCheck: Self.now.addingTimeInterval(-60), automatic: true, now: Self.now))
        #expect(UpdateCheckPolicy.shouldCheck(.launch, lastCheck: nil, automatic: true, now: Self.now))
    }

    /// Waking and opening Settings happen many times a day; each asks at
    /// most once per 24 hours.
    @Test(arguments: [UpdateCheckTrigger.wake, .settingsOpened])
    func wakeAndSettingsAreThrottledToADay(_ trigger: UpdateCheckTrigger) {
        let check = { (ago: TimeInterval?) in
            UpdateCheckPolicy.shouldCheck(
                trigger, lastCheck: ago.map { Self.now.addingTimeInterval(-$0) }, automatic: true, now: Self.now
            )
        }
        #expect(check(nil), "never checked")
        #expect(!check(60))
        #expect(!check(23 * Self.hour))
        #expect(!check(24 * Self.hour - 1))
        #expect(check(24 * Self.hour))
        #expect(check(72 * Self.hour))
    }

    /// A last check in the future means the clock moved back. Waiting for
    /// the clock to catch up could mean never checking, so it counts as
    /// stale.
    @Test func aLastCheckInTheFutureIsStale() {
        #expect(UpdateCheckPolicy.shouldCheck(.wake, lastCheck: Self.now.addingTimeInterval(Self.hour), automatic: true, now: Self.now))
    }

    @Test func theThrottleIsADay() {
        #expect(UpdateCheckPolicy.interval == 24 * Self.hour)
    }

    // MARK: - The record

    private static let release = Release(
        tag: "v0.13.0",
        notesURL: URL(string: "https://github.com/GcdZ03/CreativeNotch/releases/tag/v0.13.0")!,
        archiveURL: URL(string: "https://github.com/GcdZ03/CreativeNotch/releases/download/v0.13.0/CreativeNotch-v0.13.0.tar.gz")!,
        checksumURL: URL(string: "https://github.com/GcdZ03/CreativeNotch/releases/download/v0.13.0/CreativeNotch-v0.13.0.tar.gz.sha256")!
    )

    @Test func aFreshReplyReplacesTheRecord() {
        let old = UpdateRecord(lastCheck: Self.now.addingTimeInterval(-Self.hour), etag: "old", release: nil)
        let next = old.applying(.fresh(Self.release, etag: "new"), at: Self.now)
        #expect(next == UpdateRecord(lastCheck: Self.now, etag: "new", release: Self.release))
    }

    @Test func notModifiedOnlyMovesTheDate() {
        let old = UpdateRecord(lastCheck: Self.now.addingTimeInterval(-Self.hour), etag: "e", release: Self.release)
        #expect(old.applying(.notModified, at: Self.now) == UpdateRecord(lastCheck: Self.now, etag: "e", release: Self.release))
    }

    /// A failure is not a check: the next wake tries again rather than
    /// waiting a day after being offline.
    @Test(arguments: [UpdateCheckFailure.offline, .rateLimited, .unexpected])
    func aFailureChangesNothing(_ failure: UpdateCheckFailure) {
        let old = UpdateRecord(lastCheck: Self.now.addingTimeInterval(-Self.hour), etag: "e", release: Self.release)
        #expect(old.applying(.failed(failure), at: Self.now) == old)
    }

    /// A 304 has no body, so an ETag is worth sending only alongside the
    /// release it describes. Without one, the reply must be a full 200.
    @Test func theETagIsSentOnlyWithItsRelease() {
        #expect(UpdateRecord(lastCheck: nil, etag: "e", release: Self.release).conditionalETag == "e")
        #expect(UpdateRecord(lastCheck: nil, etag: "e", release: nil).conditionalETag == nil)
        #expect(UpdateRecord(lastCheck: nil, etag: nil, release: Self.release).conditionalETag == nil)
        #expect(UpdateRecord(lastCheck: nil, etag: "", release: Self.release).conditionalETag == nil)
    }

    /// Stored values are read by the same policy as every other key: the
    /// wrong type reads as absent.
    @Test func resolvesStoredValues() throws {
        let encoded = try JSONEncoder().encode(Self.release)
        let record = UpdateRecord.resolve(lastCheck: 1_800_000_000.0, etag: "e", release: encoded)
        #expect(record == UpdateRecord(lastCheck: Self.now, etag: "e", release: Self.release))
        #expect(UpdateRecord.resolve(lastCheck: "yesterday", etag: 4, release: Data("x".utf8)) == UpdateRecord())
        #expect(UpdateRecord.resolve(lastCheck: nil, etag: nil, release: nil) == UpdateRecord())
    }

    // MARK: - What Settings says

    private static let english = Locale(identifier: "en_US")

    @Test func theSettledStatusComesFromTheRecord() {
        #expect(UpdateStatus.settled(record: UpdateRecord(), currentVersion: "0.12.0") == .notChecked)
        #expect(UpdateStatus.settled(
            record: UpdateRecord(lastCheck: Self.now, etag: nil, release: nil), currentVersion: "0.12.0"
        ) == .upToDate(checkedAt: Self.now))
        #expect(UpdateStatus.settled(
            record: UpdateRecord(lastCheck: Self.now, etag: nil, release: Self.release), currentVersion: "0.12.0"
        ) == .available(Self.release))
        // Once the update is installed, the cached release is this one.
        #expect(UpdateStatus.settled(
            record: UpdateRecord(lastCheck: Self.now, etag: nil, release: Self.release), currentVersion: "0.13.0"
        ) == .upToDate(checkedAt: Self.now))
    }

    @Test func statusLines() {
        let line = { (status: UpdateStatus) in status.line(now: Self.now, locale: Self.english) }
        #expect(line(.notChecked) == "Not checked yet")
        #expect(line(.checking) == "Checking\u{2026}")
        #expect(line(.upToDate(checkedAt: Self.now.addingTimeInterval(-300))) == "Up to date \u{2014} checked 5 minutes ago")
        #expect(line(.upToDate(checkedAt: Self.now.addingTimeInterval(-26 * Self.hour))) == "Up to date \u{2014} checked yesterday")
        #expect(line(.available(Self.release)) == "Version 0.13.0 is available")
        #expect(line(.installing(Self.release, .downloading)) == "Downloading\u{2026}")
        #expect(line(.installing(Self.release, .verifying)) == "Verifying\u{2026}")
        #expect(line(.installing(Self.release, .installing)) == "Installing\u{2026}")
        #expect(line(.relaunching(Self.release)) == "Restarting\u{2026}")
        #expect(line(.checkFailed(.offline)).hasPrefix("Couldn't check for updates"))
        #expect(line(.checkFailed(.rateLimited)).hasPrefix("Couldn't check for updates"))
        #expect(line(.checkFailed(.unexpected)) == "Couldn't check for updates")
        #expect(line(.installFailed(Self.release, .checksumMismatch)).hasPrefix("Couldn't update:"))
    }

    /// A clock that moved back does not say "checked in 5 minutes".
    @Test func aCheckInTheFutureReadsAsNow() {
        let line = UpdateStatus.upToDate(checkedAt: Self.now.addingTimeInterval(300)).line(now: Self.now, locale: Self.english)
        #expect(!line.contains("in 5"))
    }

    @Test func busyStates() {
        #expect(UpdateStatus.checking.isBusy)
        #expect(UpdateStatus.installing(Self.release, .verifying).isBusy)
        #expect(UpdateStatus.relaunching(Self.release).isBusy)
        #expect(!UpdateStatus.available(Self.release).isBusy)
        #expect(!UpdateStatus.notChecked.isBusy)
        #expect(!UpdateStatus.installFailed(Self.release, .moveFailed).isBusy)
    }

    /// The release an "Update Now" acts on: offered, or offered again after
    /// a failed attempt.
    @Test func whichStatesOfferAnInstall() {
        #expect(UpdateStatus.available(Self.release).installableRelease == Self.release)
        #expect(UpdateStatus.installFailed(Self.release, .moveFailed).installableRelease == Self.release)
        #expect(UpdateStatus.checking.installableRelease == nil)
        #expect(UpdateStatus.installing(Self.release, .downloading).installableRelease == nil)
        let bare = Release(tag: "v0.13.0", notesURL: Self.release.notesURL, archiveURL: nil, checksumURL: nil)
        #expect(UpdateStatus.available(bare).installableRelease == nil, "no assets, nothing to install")
        #expect(UpdateStatus.available(bare).release == bare, "but still announced, with notes")
    }

    @Test func everyFailureHasAReason() {
        let failures: [UpdateInstallFailure] = [
            .notInstallable, .downloadFailed, .checksumUnreadable, .checksumMismatch, .extractFailed,
            .appMissing, .signatureInvalid, .versionMismatch(found: "0.12.0"), .versionMismatch(found: nil),
            .moveFailed, .restoreFailed(backupPath: "/Applications/.CreativeNotch.app.previous.42"),
        ]
        let reasons = failures.map(\.reason)
        #expect(reasons.allSatisfy { !$0.isEmpty })
        #expect(Set(reasons).count == reasons.count)
        #expect(UpdateInstallFailure.restoreFailed(backupPath: "/A/.B").reason.contains("/A/.B"))
    }
}
