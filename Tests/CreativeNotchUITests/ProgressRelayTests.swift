import Foundation
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// The real subscriber's off-main half, driven with local `Progress` objects.
///
/// Key-value observation of a `Progress` in this process is synchronous, so
/// these exercise the real observations, the filter and the per-percent
/// dedupe with no browser, no published progress and no waiting. Delivery is
/// handed a recorder instead of the hop to the main queue.
struct ProgressRelayTests {

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [DownloadEvent] = []
        var events: [DownloadEvent] { lock.lock(); defer { lock.unlock() }; return _events }
        func record(_ event: DownloadEvent) { lock.lock(); _events.append(event); lock.unlock() }
    }

    private let file = URL(fileURLWithPath: "/nonexistent/Downloads/report.pdf.download")

    private func progress(
        total: Int64 = 1_000,
        kind: Progress.FileOperationKind? = .downloading,
        url: URL? = nil
    ) -> Progress {
        let progress = Progress(parent: nil, userInfo: nil)
        progress.totalUnitCount = total
        progress.kind = .file
        progress.fileOperationKind = kind
        progress.fileURL = url ?? file
        return progress
    }

    private func relay() -> (ProgressRelay, Recorder) {
        let recorder = Recorder()
        return (ProgressRelay(deliver: { recorder.record($0) }), recorder)
    }

    @Test func aDownloadIsPublishedWithItsReading() throws {
        let (relay, recorder) = relay()
        let p = progress()
        p.completedUnitCount = 420

        let handler = relay.published(p)

        #expect(handler != nil)
        #expect(relay.observedCount == 1)
        guard case .published(_, let reading)? = recorder.events.first else {
            Issue.record("nothing published"); return
        }
        #expect(reading.fileURL == file)
        #expect(reading.completed == 420)
        #expect(reading.total == 1_000)
    }

    /// Finder copying a file into Downloads publishes a progress too. It is
    /// not watched at all: no handler, no observation, nothing delivered.
    @Test func aCopyIsNotWatched() {
        let (relay, recorder) = relay()
        let handler = relay.published(progress(kind: .copying, url: URL(fileURLWithPath: "/x/a.zip")))
        #expect(handler == nil)
        #expect(relay.observedCount == 0)
        #expect(recorder.events.isEmpty)
    }

    /// The main thread wakes once per whole percent, not once per chunk.
    @Test func bytesWithinAPercentAreNotForwarded() {
        let (relay, recorder) = relay()
        let p = progress(total: 10_000)
        _ = relay.published(p)

        p.completedUnitCount = 50      // 0%
        p.completedUnitCount = 99      // 0%
        p.completedUnitCount = 100     // 1%
        p.completedUnitCount = 150     // 1%
        p.completedUnitCount = 10_000  // 100%

        let changes = recorder.events.compactMap { event -> Int? in
            if case .changed(_, let reading) = event { return reading.percent }
            return nil
        }
        #expect(changes == [1, 100])
    }

    @Test func cancellingIsForwarded() {
        let (relay, recorder) = relay()
        let p = progress()
        _ = relay.published(p)
        p.cancel()
        guard case .changed(_, let reading)? = recorder.events.last else {
            Issue.record("cancel not forwarded"); return
        }
        #expect(reading.isCancelled)
    }

    /// The unpublishing handler reports the end and drops the observations,
    /// so a later change to the same object is not delivered.
    @Test func unpublishingReportsTheEndAndStopsObserving() throws {
        let (relay, recorder) = relay()
        let p = progress()
        let handler = try #require(relay.published(p))

        handler()
        p.completedUnitCount = 900

        #expect(relay.observedCount == 0)
        guard case .unpublished? = recorder.events.last else {
            Issue.record("unpublish not reported"); return
        }
        #expect(recorder.events.count == 2)
    }

    /// Stopping drops every observation; nothing arrives afterwards, and a
    /// progress published after it is not watched.
    @Test func invalidatingStopsEverything() throws {
        let (relay, recorder) = relay()
        let p = progress()
        let handler = try #require(relay.published(p))

        relay.invalidate()
        p.completedUnitCount = 900
        handler()
        let later = relay.published(progress())

        #expect(recorder.events.count == 1)
        #expect(later == nil)
        #expect(relay.observedCount == 0)
    }

    /// The real source subscribes and unsubscribes. Pointed at a temporary
    /// folder, which needs no permission and has nothing downloading into it.
    @Test @MainActor func theRealSourceSubscribesAndUnsubscribes() {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("CreativeNotchDownloads-\(UUID().uuidString)", isDirectory: true)
        let source = FileProgressSource()
        source.start(watching: folder) { _ in }
        #expect(source.isSubscribed)
        source.stop()
        #expect(!source.isSubscribed)
    }
}
