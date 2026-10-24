import AppKit
import Foundation
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// The downloads module joined to the app: switch, controller, badge slot,
/// peek, Finder, Settings.
///
/// Every source here is a `FakeDownloadSource` and every access probe a
/// `FakeAccessProbe`: no test subscribes to real file progress, reads the
/// real Downloads folder, or opens Finder.
@MainActor
struct DownloadsWiringTests {

    private func makeDelegate(granted: Bool = true) -> (AppDelegate, FakeDownloadSource, FakeAccessProbe) {
        let source = FakeDownloadSource()
        let probe = FakeAccessProbe(granted: granted)
        let delegate = AppDelegate()
        delegate.shelfTrash = TestTrash.shelf
        delegate.preferencesDefaults = TestDefaults.isolated("downloads")
        delegate.growthDelay = .zero
        delegate.playChime = { _ in }
        delegate.performHaptic = {}
        delegate.announce = { _ in }
        delegate.pointerLocation = { CGPoint(x: -10_000, y: -10_000) }
        delegate.screenDescriptors = { [] }
        delegate.makeDownloadSource = { source }
        delegate.probeDownloadsAccess = probe.probe
        delegate.powerTTLDelay = .seconds(3600)
        delegate.downloadDoneTTLDelay = .seconds(3600)
        // Opening the panel must install no real global monitor and take no
        // real key focus.
        delegate.installOutsideClickMonitor = { _ in nil }
        delegate.takeKey = {}
        delegate.relinquishKey = {}
        delegate.install(metrics: NotchedDelegate.metrics)
        delegate.capture?.observer.readCurrentUse = { .none }
        delegate.clipboard?.poller.scheduleTimer = { _, _ in nil }
        delegate.clipboard?.poller.cancelTimer = { _ in }
        delegate.media?.supervisor.startHelper = {}
        delegate.media?.supervisor.stopHelper = {}
        return (delegate, source, probe)
    }

    private func reading(_ name: String, _ completed: Int64, of total: Int64) -> DownloadReading {
        DownloadReading(
            fileURL: URL(fileURLWithPath: "/nonexistent/Downloads").appendingPathComponent(name),
            completed: completed, total: total
        )
    }

    private func switchOn(_ delegate: AppDelegate) async {
        delegate.switchboard.setEnabled(true, for: .downloads)
        await delegate.downloads?.accessTask?.value
    }

    // MARK: - Ships off

    /// A fresh install applies its preferences and downloads stays off:
    /// nothing reads the Downloads folder, so macOS asks nothing at launch.
    @Test func aFreshLaunchNeitherAsksNorSubscribes() async {
        let (delegate, source, probe) = makeDelegate()
        delegate.switchboard.apply()
        await delegate.downloads?.accessTask?.value

        #expect(delegate.state.preferences.downloads == false)
        #expect(probe.count == 0)
        #expect(source.startCount == 0)
    }

    /// Switched on and saved, the next launch asks and subscribes: the
    /// launch path is the same code a live toggle runs.
    @Test func aSavedSwitchIsHonouredAtLaunch() async {
        let (delegate, source, _) = makeDelegate()
        delegate.preferencesStore.setEnabled(true, for: .downloads)
        delegate.switchboard.apply()
        await delegate.downloads?.accessTask?.value
        #expect(source.startCount == 1)
    }

    @Test func installBuildsTheControllerOnTheSandboxedFolder() throws {
        let (delegate, _, _) = makeDelegate()
        let downloads = try #require(delegate.downloads)
        #expect(downloads.folder == delegate.downloadsDirectory)
        #expect(downloads.folder != AppDelegate.realDownloadsDirectory)
        #expect(downloads.folder.standardizedFileURL.path
            .hasPrefix(FileManager.default.temporaryDirectory.standardizedFileURL.path))
    }

    /// The real locations and verbs are switched on by the launch alone.
    @Test func theRealLaunchPointsAtTheRealDownloadsFolder() {
        let delegate = AppDelegate()
        #expect(delegate.downloadsDirectory != AppDelegate.realDownloadsDirectory)
        delegate.configureForRealLaunch()
        #expect(delegate.downloadsDirectory == AppDelegate.realDownloadsDirectory)
        #expect(AppDelegate.realDownloadsDirectory.lastPathComponent == "Downloads")
    }

    // MARK: - The badge

    @Test func aRunningDownloadTakesTheSlotAndWidensWhatAcceptsClicks() async {
        let (delegate, source, _) = makeDelegate()
        await switchOn(delegate)
        let closedWidth = delegate.acceptedRect.width

        source.send(.published(DownloadID(), reading("a.zip.download", 42, of: 100)))

        #expect(delegate.state.downloads?.percent == 42)
        #expect(delegate.currentBadgeSlot == .downloads)
        #expect(delegate.acceptedRect.width == closedWidth + NotchGeometry.downloadsBadgeWidth)
        #expect(NotchRootView.drawnRect(for: delegate.state).width == delegate.acceptedRect.width)
    }

    /// Off removes the badge and narrows the notch again at once -- a stale
    /// badge would keep swallowing menu bar clicks for the session.
    @Test func switchingOffTakesTheBadgeAway() async {
        let (delegate, source, _) = makeDelegate()
        await switchOn(delegate)
        source.send(.published(DownloadID(), reading("a.zip.download", 42, of: 100)))
        let widened = delegate.acceptedRect.width

        delegate.switchboard.setEnabled(false, for: .downloads)

        #expect(source.stopCount == 1)
        #expect(delegate.state.downloads == nil)
        #expect(delegate.currentBadgeSlot == .none)
        #expect(delegate.acceptedRect.width == widened - NotchGeometry.downloadsBadgeWidth)
    }

    /// A completion peek on screen when the switch goes off is withdrawn at
    /// once, not left to its TTL: a peek outliving its module is what makes
    /// a preference feel unreliable.
    @Test func switchingOffWithdrawsAShowingCompletion() async {
        let (delegate, source, _) = makeDelegate()
        await switchOn(delegate)
        let id = DownloadID()
        source.send(.published(id, reading("a.download", 10, of: 10)))
        source.send(.unpublished(id))
        if case .peek(.downloadDone) = delegate.state.state {} else {
            Issue.record("expected the completion peek first"); return
        }

        delegate.switchboard.setEnabled(false, for: .downloads)

        #expect(delegate.state.state == .closed)
        #expect(delegate.arbiter.content(now: delegate.now()) == nil)
    }

    @Test func quittingStopsTheSubscription() async {
        let (delegate, source, _) = makeDelegate()
        await switchOn(delegate)
        delegate.switchboard.stopAll()
        #expect(source.stopCount == 1)
    }

    // MARK: - The peeks

    @Test func hoveringTheBadgeShowsTheProgressPeek() async {
        let (delegate, source, _) = makeDelegate()
        await switchOn(delegate)
        source.send(.published(DownloadID(), reading("a.zip.download", 42, of: 100)))

        delegate.hoverView?.onDwell()

        guard case .peek(.downloads(let summary)) = delegate.state.state else {
            Issue.record("expected the downloads peek, got \(delegate.state.state)"); return
        }
        #expect(summary.title == "a.zip")
    }

    /// The progress peek follows the percent while the pointer is on it.
    @Test func theProgressPeekFollowsThePercentUnderThePointer() async {
        let (delegate, source, _) = makeDelegate()
        await switchOn(delegate)
        let id = DownloadID()
        source.send(.published(id, reading("a.zip.download", 42, of: 100)))
        delegate.hoverView?.onEnter()
        delegate.hoverView?.onDwell()

        source.send(.changed(id, reading("a.zip.download", 60, of: 100)))

        #expect(delegate.state.state == .peek(.downloads(DownloadSummary(count: 1, percent: 60, leadingName: "a.zip"))))
    }

    @Test func aFinishedDownloadPeeksAndIsAnnounced() async {
        let (delegate, source, _) = makeDelegate()
        var spoken: [String] = []
        delegate.announce = { spoken.append($0) }
        await switchOn(delegate)
        let id = DownloadID()
        source.send(.published(id, reading("report.pdf.download", 10, of: 10)))
        source.send(.unpublished(id))

        guard case .peek(.downloadDone(let done)) = delegate.state.state else {
            Issue.record("expected the completion peek, got \(delegate.state.state)"); return
        }
        #expect(done.name == "report.pdf")
        #expect(spoken == ["Downloaded report.pdf"])
        // The badge has gone with the last download.
        #expect(delegate.currentBadgeSlot == .none)
    }

    /// The last download finishing under the pointer turns the progress peek
    /// into the completion without closing in between.
    @Test func theProgressPeekBecomesTheCompletionWithoutClosing() async {
        let (delegate, source, _) = makeDelegate()
        await switchOn(delegate)
        let id = DownloadID()
        source.send(.published(id, reading("a.zip.download", 99, of: 100)))
        delegate.hoverView?.onEnter()
        delegate.hoverView?.onDwell()
        var states: [NotchState] = []
        let token = delegate.state.observe { if case .state(let s) = $0 { states.append(s) } }
        defer { delegate.state.removeObserver(token) }

        source.send(.changed(id, reading("a.zip.download", 100, of: 100)))
        source.send(.unpublished(id))

        #expect(!states.contains(.closed))
        if case .peek(.downloadDone) = delegate.state.state {} else {
            Issue.record("expected the completion peek, got \(delegate.state.state)")
        }
    }

    /// Clicking the completion shows the file in Finder, closes the peek and
    /// acknowledges it, so the next hover does not show it again.
    @Test func clickingTheCompletionRevealsTheFile() async {
        let (delegate, source, _) = makeDelegate()
        var revealed: [URL] = []
        delegate.revealInFinder = { revealed.append($0) }
        await switchOn(delegate)
        let id = DownloadID()
        source.send(.published(id, reading("report.pdf.download", 10, of: 10)))
        source.send(.unpublished(id))

        NotchRootView.handleTap(app: delegate.state)

        #expect(revealed == [URL(fileURLWithPath: "/nonexistent/Downloads/report.pdf")])
        #expect(delegate.state.state == .closed)
        #expect(delegate.arbiter.content(now: delegate.now()) == nil)
    }

    /// VoiceOver's activate reaches the same verb.
    @Test func theCompletionsAccessibilityActionRevealsTheFileToo() {
        let (delegate, _, _) = makeDelegate()
        var revealed: [URL] = []
        delegate.revealInFinder = { revealed.append($0) }
        let done = DownloadCompletion(name: "a.zip", url: URL(fileURLWithPath: "/x/a.zip"))

        NotchRootView.downloadPeek(for: delegate.state, content: .done(done)).onReveal?()

        #expect(revealed == [URL(fileURLWithPath: "/x/a.zip")])
    }

    /// Opening the panel is having seen it.
    @Test func openingThePanelAcknowledgesTheCompletion() async {
        let (delegate, source, _) = makeDelegate()
        await switchOn(delegate)
        let id = DownloadID()
        source.send(.published(id, reading("a.download", 10, of: 10)))
        source.send(.unpublished(id))

        delegate.openPanel(openedBy: .tap)
        delegate.state.transition(to: .closed)

        #expect(delegate.arbiter.content(now: delegate.now()) == nil)
    }

    /// Behind the lock screen a download finishing shows nothing then and
    /// nothing later.
    @Test func aDownloadFinishingWhileLockedDoesNotPeek() async {
        let (delegate, source, _) = makeDelegate()
        await switchOn(delegate)
        delegate.switchboard.setActivity(.locked)
        let id = DownloadID()
        source.send(.published(id, reading("a.download", 10, of: 10)))
        source.send(.unpublished(id))

        #expect(delegate.state.state == .closed)
        #expect(delegate.arbiter.content(now: delegate.now()) == nil)
        #expect(delegate.downloads?.isSubscribed == true)
    }

    @Test func theCompletionPeekIsReCheckedOnItsOwnTTL() {
        let done = DownloadCompletion(name: "a", url: nil)
        let delay = AppDelegate.reevaluationDelay(
            for: .downloadDone(done), power: .seconds(1), timerDone: .seconds(2), downloadDone: .seconds(3)
        )
        #expect(delay == .seconds(3))
        #expect(AppDelegate.defaultDownloadDoneTTLDelay == .seconds(Int(PeekArbiter.downloadDoneTTL)))
    }

    // MARK: - Settings

    private func makeController(_ delegate: AppDelegate) -> PreferencesController {
        PreferencesController(
            switchboard: delegate.switchboard,
            state: delegate.state,
            launchAtLogin: delegate.launchAtLogin,
            presenter: { _ in }
        )
    }

    @Test func theRowWarnsOnlyWhileOnAndRefused() async {
        let (delegate, _, _) = makeDelegate(granted: false)
        let controller = makeController(delegate)
        #expect(PreferencesView.warning(for: .downloads, controller: controller) == nil)

        controller.setEnabled(true, for: .downloads)
        await delegate.downloads?.accessTask?.value

        #expect(delegate.state.downloadsAccess == .denied)
        #expect(PreferencesView.warning(for: .downloads, controller: controller) == DownloadsAccess.denied.warning)
        #expect(PreferencesView.offersPrivacySettings(.downloads, controller: controller))

        controller.setEnabled(false, for: .downloads)
        #expect(PreferencesView.warning(for: .downloads, controller: controller) == nil)
        #expect(!PreferencesView.offersPrivacySettings(.downloads, controller: controller))
    }

    @Test func aGrantedRowDoesNotWarn() async {
        let (delegate, _, _) = makeDelegate(granted: true)
        let controller = makeController(delegate)
        controller.setEnabled(true, for: .downloads)
        await delegate.downloads?.accessTask?.value
        #expect(PreferencesView.warning(for: .downloads, controller: controller) == nil)
    }

    /// Showing Settings asks again after a refusal, so permission granted in
    /// System Settings takes effect when the person comes back to look.
    @Test func showingSettingsAsksAgainAfterARefusal() async {
        let (delegate, _, probe) = makeDelegate(granted: false)
        let controller = makeController(delegate)
        controller.setEnabled(true, for: .downloads)
        await delegate.downloads?.accessTask?.value
        #expect(probe.count == 1)

        controller.show()
        await delegate.downloads?.accessTask?.value

        #expect(probe.count == 2)
    }

    @Test func theDeniedRowsButtonOpensPrivacySettings() {
        let (delegate, _, _) = makeDelegate()
        var opened = 0
        delegate.openDownloadsPrivacySettings = { opened += 1 }
        makeController(delegate).openDownloadsPrivacy()
        #expect(opened == 1)
        #expect(AppDelegate.filesAndFoldersSettings != nil)
    }

    /// The prompt's text exists: without it macOS refuses to ask at all.
    @Test func theInfoPlistExplainsTheDownloadsPrompt() throws {
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Info.plist")
        let data = try Data(contentsOf: plist)
        let dict = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let text = try #require(dict["NSDownloadsFolderUsageDescription"] as? String)
        #expect(text.contains("Downloads"))
    }
}
