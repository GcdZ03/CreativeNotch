import Foundation
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// A stand-in for file progress publishing: records what it was asked to do
/// and plays whatever events a test hands it.
@MainActor
final class FakeDownloadSource: DownloadProgressSource {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var folder: URL?
    private var onEvent: (@MainActor @Sendable (DownloadEvent) -> Void)?

    var isRunning: Bool { onEvent != nil }

    func start(watching folder: URL, onEvent: @escaping @MainActor @Sendable (DownloadEvent) -> Void) {
        startCount += 1
        self.folder = folder
        self.onEvent = onEvent
    }

    func stop() {
        stopCount += 1
        onEvent = nil
    }

    /// Delivers `event` as the real source would. Deliberately also usable
    /// after `stop()` via `sendLate`, to model a callback already in flight.
    func send(_ event: DownloadEvent) { onEvent?(event) }

    private var lastHandler: (@MainActor @Sendable (DownloadEvent) -> Void)?
    func keepHandler() { lastHandler = onEvent }
    func sendLate(_ event: DownloadEvent) { lastHandler?(event) }
}

/// Counts probes and answers them, never touching a real folder.
final class FakeAccessProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    private let answer: Bool

    init(granted: Bool) { self.answer = granted }

    var count: Int { lock.lock(); defer { lock.unlock() }; return _count }

    private func record() -> Bool {
        lock.lock(); defer { lock.unlock() }
        _count += 1
        return answer
    }

    var probe: DownloadsController.AccessProbe {
        { [self] _ in record() }
    }
}

/// A probe that waits until a test lets it answer -- macOS's prompt still on
/// screen.
actor HeldProbe {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

@MainActor
struct DownloadsControllerTests {

    private let folder = URL(fileURLWithPath: "/nonexistent/Downloads", isDirectory: true)

    private func reading(_ name: String, _ completed: Int64, of total: Int64) -> DownloadReading {
        DownloadReading(fileURL: folder.appendingPathComponent(name), completed: completed, total: total)
    }

    private func make(
        granted: Bool = true,
        fileExists: @escaping (URL) -> Bool = { _ in false }
    ) -> (DownloadsController, FakeDownloadSource, FakeAccessProbe) {
        let source = FakeDownloadSource()
        let probe = FakeAccessProbe(granted: granted)
        let controller = DownloadsController(
            folder: folder, source: source, probeAccess: probe.probe, fileExists: fileExists
        )
        return (controller, source, probe)
    }

    // MARK: - Nothing runs until asked

    /// Building one reads no folder and subscribes to nothing: the read is a
    /// privacy prompt, and building a panel must not prompt.
    @Test func constructingReadsNothingAndSubscribesNothing() {
        let (controller, source, probe) = make()
        #expect(probe.count == 0)
        #expect(source.startCount == 0)
        #expect(controller.access == .unknown)
    }

    @Test func switchingOnAsksForTheFolderThenSubscribesToIt() async {
        let (controller, source, probe) = make()
        var accesses: [DownloadsAccess] = []
        controller.onAccess = { accesses.append($0) }

        controller.setEnabled(true)
        await controller.accessTask?.value

        #expect(probe.count == 1)
        #expect(controller.access == .granted)
        #expect(accesses == [.granted])
        #expect(source.startCount == 1)
        #expect(source.folder == folder)
        #expect(controller.isSubscribed)
    }

    /// Refused: nothing is subscribed, and the state says so rather than
    /// leaving a switch reading "on" over a module that sees nothing.
    @Test func aRefusalSubscribesNothingAndSaysSo() async {
        let (controller, source, _) = make(granted: false)
        controller.setEnabled(true)
        await controller.accessTask?.value

        #expect(controller.access == .denied)
        #expect(source.startCount == 0)
        #expect(!controller.isSubscribed)
    }

    /// Switched off while macOS was still asking: the answer arrives for
    /// nobody, and nothing subscribes.
    @Test func switchingOffWhileAskingSubscribesNothing() async {
        let source = FakeDownloadSource()
        let held = HeldProbe()
        let controller = DownloadsController(
            folder: folder, source: source,
            probeAccess: { _ in await held.wait(); return true },
            fileExists: { _ in false }
        )
        controller.setEnabled(true)
        let task = controller.accessTask
        controller.setEnabled(false)
        await held.open()
        await task?.value

        #expect(source.startCount == 0)
        #expect(controller.access == .unknown)
    }

    // MARK: - Off stops everything

    @Test func switchingOffStopsTheSubscriptionAndClearsTheBadge() async {
        let (controller, source, _) = make()
        var summaries: [DownloadSummary?] = []
        controller.onSummary = { summaries.append($0) }
        controller.setEnabled(true)
        await controller.accessTask?.value
        source.send(.published(DownloadID(), reading("a.zip.download", 10, of: 100)))

        controller.setEnabled(false)

        #expect(source.stopCount == 1)
        #expect(!source.isRunning)
        #expect(!controller.isSubscribed)
        #expect(controller.tracker.summary == nil)
        #expect(summaries.last == .some(nil))
        #expect(controller.access == .unknown)
    }

    /// A callback already in flight when the switch went off publishes
    /// nothing -- the capture indicator's `isStopped` backstop.
    @Test func aLateEventAfterStoppingPublishesNothing() async {
        let (controller, source, _) = make()
        var summaries = 0
        controller.onSummary = { _ in summaries += 1 }
        controller.setEnabled(true)
        await controller.accessTask?.value
        source.keepHandler()
        controller.setEnabled(false)

        source.sendLate(.published(DownloadID(), reading("a.zip.download", 10, of: 100)))

        #expect(summaries == 0)
        #expect(controller.tracker.summary == nil)
    }

    // MARK: - Publishing

    /// Readings in the same whole percent are the same ring, and are not
    /// republished: a browser writing chunk after chunk redraws nothing.
    @Test func onlyAChangedSummaryIsPublished() async {
        let (controller, source, _) = make()
        var summaries: [DownloadSummary?] = []
        controller.onSummary = { summaries.append($0) }
        controller.setEnabled(true)
        await controller.accessTask?.value

        let id = DownloadID()
        source.send(.published(id, reading("a.zip.download", 4_200, of: 10_000)))
        source.send(.changed(id, reading("a.zip.download", 4_250, of: 10_000)))
        source.send(.changed(id, reading("a.zip.download", 4_299, of: 10_000)))
        source.send(.changed(id, reading("a.zip.download", 4_300, of: 10_000)))

        #expect(summaries.map { $0?.percent } == [42, 43])
    }

    @Test func aFinishedDownloadIsReportedOnce() async {
        let (controller, source, _) = make()
        var completions: [DownloadCompletion] = []
        controller.onCompleted = { completions.append($0) }
        controller.setEnabled(true)
        await controller.accessTask?.value

        let id = DownloadID()
        source.send(.published(id, reading("report.pdf.download", 0, of: 10)))
        source.send(.changed(id, reading("report.pdf.download", 10, of: 10)))
        source.send(.unpublished(id))

        #expect(completions.map(\.name) == ["report.pdf"])
    }

    /// The completion is reported before the emptied summary, so a progress
    /// peek under the pointer becomes the completion in one step.
    @Test func theCompletionArrivesBeforeTheBadgeGoes() async {
        let (controller, source, _) = make()
        var order: [String] = []
        controller.onCompleted = { _ in order.append("completed") }
        controller.onSummary = { order.append($0 == nil ? "cleared" : "summary") }
        controller.setEnabled(true)
        await controller.accessTask?.value

        let id = DownloadID()
        source.send(.published(id, reading("a.download", 10, of: 10)))
        source.send(.unpublished(id))

        #expect(order == ["summary", "completed", "cleared"])
    }

    /// Behind the lock screen the ring still follows -- the badge must be
    /// right on unlock -- but the completion peek, an interruption timed to
    /// a moment, is dropped rather than replayed.
    @Test func aCompletionWhileLockedIsDroppedButTheBadgeStillFollows() async {
        let (controller, source, _) = make()
        var completions = 0
        var summaries: [DownloadSummary?] = []
        controller.onCompleted = { _ in completions += 1 }
        controller.onSummary = { summaries.append($0) }
        controller.setEnabled(true)
        await controller.accessTask?.value
        controller.setActivity(.locked)

        let id = DownloadID()
        source.send(.published(id, reading("a.download", 10, of: 10)))
        source.send(.unpublished(id))

        #expect(completions == 0)
        #expect(summaries.last == .some(nil))
        #expect(controller.isSubscribed)
    }

    // MARK: - Asking again

    /// After a refusal, asking again (Settings being shown) re-reads the
    /// folder; otherwise it reads nothing.
    @Test func recheckingReadsOnlyAfterARefusal() async {
        let (granted, _, grantedProbe) = make(granted: true)
        granted.recheckAccess()
        #expect(grantedProbe.count == 0)   // off: nothing to ask
        granted.setEnabled(true)
        await granted.accessTask?.value
        granted.recheckAccess()
        #expect(grantedProbe.count == 1)   // already granted: nothing to ask

        let (denied, _, deniedProbe) = make(granted: false)
        denied.setEnabled(true)
        await denied.accessTask?.value
        denied.recheckAccess()
        await denied.accessTask?.value
        #expect(deniedProbe.count == 2)
    }
}
