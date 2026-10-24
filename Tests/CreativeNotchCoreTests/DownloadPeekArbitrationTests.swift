import Foundation
import Testing
@testable import CreativeNotchCore

/// Where downloads sit among everything else that wants the notch: the
/// badge slot, the peek slot, and what VoiceOver hears.
struct DownloadPeekArbitrationTests {

    private let summary = DownloadSummary(count: 1, percent: 42, leadingName: "report.pdf")
    private let done = DownloadCompletion(
        name: "report.pdf", url: URL(fileURLWithPath: "/Users/someone/Downloads/report.pdf")
    )
    private let playing = TrackSnapshot(title: "Song", artist: "Artist", isPlaying: true)

    // MARK: - The module

    /// Pinned by literal, like every other module: the raw value is the
    /// middle of a shipped defaults key.
    @Test func theModulesKeyIsPinned() {
        #expect(ModuleID.downloads.rawValue == "downloads")
        #expect(PreferenceKeys.enabled(.downloads) == "module.downloads.enabled")
    }

    /// Ships off, with the other permission modules. Reading the Downloads
    /// folder is a privacy prompt, and a module that prompts on a fresh
    /// install's first launch is the prompt-with-no-reason the architecture
    /// refuses.
    @Test func downloadsShipOffWithTheOtherPermissionModules() {
        #expect(ModuleID.downloads.shippedDefault == false)
        #expect(Preferences.shipped.downloads == false)
        #expect(Preferences.allEnabled.downloads == true)
        for module in ModuleID.allCases {
            #expect(Preferences.shipped[module] == module.shippedDefault, "\(module)")
        }
    }

    // MARK: - The badge slot

    @Test func runningDownloadsTakeTheSlot() {
        #expect(NotchShape.badgeSlot(countdown: nil, nowPlaying: nil, downloads: summary, at: Date()) == .downloads)
        #expect(BadgeSlot.downloads.width == NotchGeometry.downloadsBadgeWidth)
        #expect(BadgeSlot.downloads.leadingWidth == 0)
    }

    /// Above a playing track — the badge is the only way to see a download's
    /// progress, and the track is already on the speakers — and below a
    /// countdown, which is a deadline the user set.
    @Test func downloadsRankBelowTheTimerAndAboveMusic() throws {
        let now = Date()
        let countdown = try #require(Countdown(duration: 600, startingAt: now))
        #expect(NotchShape.badgeSlot(countdown: nil, nowPlaying: playing, downloads: summary, at: now) == .downloads)
        #expect(NotchShape.badgeSlot(countdown: countdown, nowPlaying: nil, downloads: summary, at: now) == .timer)
        #expect(NotchShape.badgeSlot(countdown: nil, nowPlaying: nil, capture: CaptureUse(microphone: true, camera: false),
                                     downloads: summary, at: now) == .capture)
    }

    // MARK: - The peek slot

    @Test func runningDownloadsAreWhatAHoverShows() {
        var arbiter = PeekArbiter()
        arbiter.setDownloads(summary)
        #expect(arbiter.content(now: 0) == .downloads(summary))
    }

    /// The same order as the badge, so a hover over the download badge shows
    /// the download and not the track the badge yielded to.
    @Test func runningDownloadsOutrankMusicOnHover() {
        var arbiter = PeekArbiter()
        arbiter.setNowPlaying(playing)
        arbiter.setDownloads(summary)
        #expect(arbiter.content(now: 0) == .downloads(summary))
        arbiter.setDownloads(nil)
        #expect(arbiter.content(now: 0) == .nowPlaying(playing))
    }

    /// A finished download is transient: it shows unasked, for a few seconds,
    /// and then goes.
    @Test func aFinishedDownloadPeeksForItsTTL() {
        var arbiter = PeekArbiter()
        arbiter.recordDownloadDone(done, now: 100)
        #expect(arbiter.content(now: 100) == .downloadDone(done))
        #expect(arbiter.content(now: 100 + PeekArbiter.downloadDoneTTL - 0.01) == .downloadDone(done))
        #expect(arbiter.content(now: 100 + PeekArbiter.downloadDoneTTL) == nil)
    }

    /// Below power, which is consequential and was not asked for; below a
    /// finished timer, which the user asked to be interrupted by; above the
    /// ambient content, which yields to anything.
    @Test func aFinishedDownloadRanksBelowPowerAndAboveAmbientContent() {
        var arbiter = PeekArbiter()
        arbiter.setNowPlaying(playing)
        arbiter.setDownloads(summary)
        arbiter.recordDownloadDone(done, now: 0)
        #expect(arbiter.content(now: 0) == .downloadDone(done))

        arbiter.recordPower(.unplugged(level: 50), now: 0)
        #expect(arbiter.content(now: 0) == .power(.unplugged(level: 50)))

        arbiter.recordTimerFinished(TimerCompletion(duration: 60, lateness: 0), now: 0)
        #expect(arbiter.content(now: 0) == .timerDone(TimerCompletion(duration: 60, lateness: 0)))
    }

    /// Below a Bluetooth device: that peek is 2.5 s confirming something the
    /// person just did, and the 5 s completion is still there once it has
    /// gone. The other order would hide the Bluetooth peek entirely.
    @Test func aBluetoothPeekCoversAFinishedDownloadAndThenRevealsIt() {
        let airPods = BluetoothAudioEvent(name: "AirPods", kind: .airPodsPro, connected: true)
        var arbiter = PeekArbiter()
        arbiter.setDownloads(summary)
        arbiter.recordDownloadDone(done, now: 0)
        arbiter.recordBluetooth(airPods, now: 0)
        #expect(arbiter.content(now: 0) == .bluetooth(airPods))
        #expect(arbiter.content(now: PeekArbiter.bluetoothTTL) == .downloadDone(done))
        #expect(arbiter.content(now: PeekArbiter.downloadDoneTTL) == .downloads(summary))
        #expect(PeekArbiter.bluetoothTTL < PeekArbiter.downloadDoneTTL)
    }

    /// Bluetooth outranks downloads in progress too, like every transient
    /// peek outranks ambient content; power outranks all of them.
    @Test func theFullOrderIncludesBluetooth() {
        let airPods = BluetoothAudioEvent(name: "AirPods", kind: .airPodsPro, connected: true)
        var arbiter = PeekArbiter()
        arbiter.setNowPlaying(playing)
        arbiter.setDownloads(summary)
        arbiter.recordBluetooth(airPods, now: 0)
        #expect(arbiter.content(now: 0) == .bluetooth(airPods))
        arbiter.recordDownloadDone(done, now: 0)
        #expect(arbiter.content(now: 0) == .bluetooth(airPods))
        arbiter.recordPower(.unplugged(level: 50), now: 0)
        #expect(arbiter.content(now: 0) == .power(.unplugged(level: 50)))
        arbiter.clearBluetooth()
        arbiter.clearPower()
        #expect(arbiter.content(now: 0) == .downloadDone(done))
        arbiter.clearDownloads()
        #expect(arbiter.content(now: 0) == .nowPlaying(playing))
    }

    /// Switching Bluetooth off withdraws its own peek only, revealing the
    /// completion queued behind it.
    @Test func clearingBluetoothRevealsAQueuedCompletion() {
        let airPods = BluetoothAudioEvent(name: "AirPods", kind: .airPodsPro, connected: false)
        var arbiter = PeekArbiter()
        arbiter.recordDownloadDone(done, now: 0)
        arbiter.recordBluetooth(airPods, now: 0)
        arbiter.clearBluetooth()
        #expect(arbiter.content(now: 0) == .downloadDone(done))
    }

    @Test func revealingAFinishedDownloadAcknowledgesIt() {
        var arbiter = PeekArbiter()
        arbiter.recordDownloadDone(done, now: 0)
        arbiter.dismissDownloadDone()
        #expect(arbiter.content(now: 0) == nil)
    }

    /// Switching the module off withdraws both of its entries — and only
    /// its own, so whatever was queued behind them is revealed.
    @Test func clearingDownloadsWithdrawsOnlyTheirOwnEntries() {
        var arbiter = PeekArbiter()
        arbiter.setNowPlaying(playing)
        arbiter.setDownloads(summary)
        arbiter.recordDownloadDone(done, now: 0)
        arbiter.clearDownloads()
        #expect(arbiter.content(now: 0) == .nowPlaying(playing))
    }

    /// Ambient, like music: a download peek on screen is kept while the
    /// pointer is over it — following the percent — and never fallen back to
    /// with nobody hovering.
    @Test func theDownloadPeekFollowsThePointerLikeMusicDoes() {
        var arbiter = PeekArbiter()
        arbiter.setDownloads(summary)
        let moved = DownloadSummary(count: 1, percent: 43, leadingName: "report.pdf")
        arbiter.setDownloads(moved)
        #expect(arbiter.content(now: 0, replacing: .downloads(summary), pointerInside: true) == .downloads(moved))
        #expect(arbiter.content(now: 0, replacing: .downloads(summary), pointerInside: false) == nil)
        // Revealed under an expiring power peek with nobody hovering: closed,
        // not left open.
        #expect(arbiter.content(now: 0, replacing: .power(.unplugged(level: 1)), pointerInside: false) == nil)
    }

    /// The last download finishing under the pointer turns the progress peek
    /// into the completion peek, rather than closing it.
    @Test func theLastDownloadFinishingUnderThePointerShowsTheCompletion() {
        var arbiter = PeekArbiter()
        arbiter.setDownloads(nil)
        arbiter.recordDownloadDone(done, now: 0)
        #expect(arbiter.content(now: 0, replacing: .downloads(summary), pointerInside: true) == .downloadDone(done))
    }

    @Test func bothDownloadPeeksAreTheStatusRow() {
        #expect(NotchState.peek(.downloads(summary)).presentation == .statusPeek)
        #expect(NotchState.peek(.downloadDone(done)).presentation == .statusPeek)
    }

    // MARK: - VoiceOver

    /// The completion is news and is spoken. The progress peek is the user's
    /// own hover answering back, like the music peek, and is not — nor is it
    /// re-announced as the percent moves under the pointer.
    @Test func onlyTheCompletionIsAnnounced() {
        #expect(PeekAnnouncement.announcement(showing: .downloadDone(done), replacing: nil) == "Downloaded report.pdf")
        #expect(PeekAnnouncement.announcement(showing: .downloads(summary), replacing: nil) == nil)
        let moved = DownloadSummary(count: 1, percent: 43, leadingName: "report.pdf")
        #expect(PeekAnnouncement.announcement(showing: .downloads(moved), replacing: .downloads(summary)) == nil)
        // Its words are still the view's label.
        #expect(PeekAnnouncement.text(for: .downloads(summary)) == "Downloading report.pdf, 42 percent")
    }
}
