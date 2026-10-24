import Foundation
import Testing
@testable import CreativeNotchCore

/// The pure half of the downloads module: what a set of file progresses
/// adds up to, what it says, and when one of them has finished.
///
/// Every reading here is synthetic. The real ones come from
/// `Progress.addSubscriber(forFileURL:)` in the UI target, and nothing in this
/// file subscribes to anything.
struct DownloadTrackerTests {

    private let downloads = URL(fileURLWithPath: "/Users/someone/Downloads", isDirectory: true)

    private func reading(
        _ name: String, _ completed: Int64, of total: Int64, cancelled: Bool = false
    ) -> DownloadReading {
        DownloadReading(
            fileURL: downloads.appendingPathComponent(name),
            completed: completed, total: total, isCancelled: cancelled
        )
    }

    private let nothingOnDisk: (URL) -> Bool = { _ in false }

    // MARK: - Names

    /// Safari downloads into a `.download` bundle and renames it at the end;
    /// Chrome and Firefox use `.crdownload` and `.part`. The name shown is the
    /// one the file will have, not the temporary one.
    @Test func theNameShownIsTheFinishedFilesName() {
        #expect(DownloadName.displayName(for: downloads.appendingPathComponent("report.pdf.download")) == "report.pdf")
        #expect(DownloadName.displayName(for: downloads.appendingPathComponent("movie.mov.crdownload")) == "movie.mov")
        #expect(DownloadName.displayName(for: downloads.appendingPathComponent("disk.dmg.part")) == "disk.dmg")
        #expect(DownloadName.displayName(for: downloads.appendingPathComponent("notes.txt")) == "notes.txt")
    }

    /// Case-insensitive, and only the last extension: a file that is really
    /// called `x.download.zip` is a zip.
    @Test func onlyATrailingPartialExtensionIsStripped() {
        #expect(DownloadName.displayName(for: downloads.appendingPathComponent("a.zip.DOWNLOAD")) == "a.zip")
        #expect(DownloadName.displayName(for: downloads.appendingPathComponent("x.download.zip")) == "x.download.zip")
    }

    @Test func aProgressWithNoFileStillHasAName() {
        #expect(DownloadName.displayName(for: nil) == "Download")
    }

    /// Finder publishes a progress for a copy *into* Downloads too. Only a
    /// download counts — or, when the publisher said nothing about the kind,
    /// a file with a browser's partial extension.
    @Test func onlyDownloadsAreTracked() {
        let partial = downloads.appendingPathComponent("a.zip.download")
        let plain = downloads.appendingPathComponent("a.zip")
        #expect(DownloadName.isDownload(operationKind: DownloadName.downloadingKind, fileURL: plain))
        #expect(!DownloadName.isDownload(operationKind: "NSProgressFileOperationKindCopying", fileURL: partial))
        #expect(DownloadName.isDownload(operationKind: nil, fileURL: partial))
        #expect(!DownloadName.isDownload(operationKind: nil, fileURL: plain))
        #expect(!DownloadName.isDownload(operationKind: nil, fileURL: nil))
    }

    // MARK: - Percent

    /// Floored, so a download never reads 100% before it has finished, and
    /// clamped, so a publisher overshooting its own total draws a full ring
    /// rather than past it.
    @Test func percentIsFlooredAndClamped() {
        #expect(reading("a", 999, of: 1000).percent == 99)
        #expect(reading("a", 1000, of: 1000).percent == 100)
        #expect(reading("a", 1500, of: 1000).percent == 100)
        #expect(reading("a", -5, of: 1000).percent == 0)
        #expect(reading("a", 0, of: 1000).percent == 0)
    }

    /// A server that sends no length gives a total of zero or -1. That is
    /// "unknown", and it must not be drawn as 0% forever.
    @Test func anUnknownTotalHasNoPercent() {
        #expect(reading("a", 500, of: 0).percent == nil)
        #expect(reading("a", 500, of: -1).percent == nil)
    }

    // MARK: - Summary

    @Test func nothingPublishedIsNoSummary() {
        #expect(DownloadTracker().summary == nil)
    }

    @Test func oneDownloadIsSummarisedByItsName() throws {
        var tracker = DownloadTracker()
        let id = DownloadID()
        tracker.apply(.published(id, reading("report.pdf.download", 420, of: 1000)), finalFileExists: nothingOnDisk)

        let summary = try #require(tracker.summary)
        #expect(summary.count == 1)
        #expect(summary.percent == 42)
        #expect(summary.title == "report.pdf")
        #expect(summary.percentText == "42%")
        #expect(summary.spoken == "Downloading report.pdf, 42 percent")
    }

    /// Several at once are one count and one aggregate, weighted by bytes:
    /// a 1 GB download at 10% and a 1 KB one at 100% are nowhere near
    /// halfway between them.
    @Test func severalDownloadsAreACountAndAByteWeightedAggregate() throws {
        var tracker = DownloadTracker()
        tracker.apply(.published(DownloadID(), reading("big.dmg.download", 100, of: 1000)), finalFileExists: nothingOnDisk)
        tracker.apply(.published(DownloadID(), reading("small.txt.download", 10, of: 10)), finalFileExists: nothingOnDisk)

        let summary = try #require(tracker.summary)
        #expect(summary.count == 2)
        #expect(summary.percent == 10)   // 110 of 1010
        #expect(summary.title == "2 downloads")
        #expect(summary.spoken == "2 downloads, 10 percent")
    }

    /// Downloads whose length is unknown are counted but cannot move the
    /// aggregate; with none known there is no percent at all.
    @Test func unknownLengthsAreCountedButNotAveraged() throws {
        var tracker = DownloadTracker()
        tracker.apply(.published(DownloadID(), reading("a.download", 50, of: 0)), finalFileExists: nothingOnDisk)
        let unknown = try #require(tracker.summary)
        #expect(unknown.percent == nil)
        #expect(unknown.percentText == nil)
        #expect(unknown.spoken == "Downloading a")

        tracker.apply(.published(DownloadID(), reading("b.download", 30, of: 100)), finalFileExists: nothingOnDisk)
        let mixed = try #require(tracker.summary)
        #expect(mixed.count == 2)
        #expect(mixed.percent == 30)
    }

    @Test func aChangeMovesThePercent() throws {
        var tracker = DownloadTracker()
        let id = DownloadID()
        tracker.apply(.published(id, reading("a.download", 10, of: 100)), finalFileExists: nothingOnDisk)
        tracker.apply(.changed(id, reading("a.download", 75, of: 100)), finalFileExists: nothingOnDisk)
        #expect(tracker.summary?.percent == 75)
    }

    /// A change for something never published — a late callback after a
    /// reset, say — is ignored rather than resurrecting an entry.
    @Test func aChangeForAnUnknownDownloadIsIgnored() {
        var tracker = DownloadTracker()
        tracker.apply(.changed(DownloadID(), reading("a.download", 10, of: 100)), finalFileExists: nothingOnDisk)
        #expect(tracker.summary == nil)
    }

    /// The order is the order they started in, so the name on the badge
    /// does not jump between two downloads as their percentages cross.
    @Test func theFirstStartedNameLeadsWhenOneIsLeft() throws {
        var tracker = DownloadTracker()
        let first = DownloadID(), second = DownloadID()
        tracker.apply(.published(first, reading("first.zip.download", 1, of: 100)), finalFileExists: nothingOnDisk)
        tracker.apply(.published(second, reading("second.zip.download", 99, of: 100)), finalFileExists: nothingOnDisk)
        tracker.apply(.unpublished(first), finalFileExists: nothingOnDisk)
        #expect(tracker.summary?.title == "second.zip")
    }

    /// A cancelled download leaves the count at once, before the browser
    /// gets round to unpublishing it.
    @Test func aCancelledDownloadLeavesTheSummary() {
        var tracker = DownloadTracker()
        let id = DownloadID()
        tracker.apply(.published(id, reading("a.download", 10, of: 100)), finalFileExists: nothingOnDisk)
        tracker.apply(.changed(id, reading("a.download", 10, of: 100, cancelled: true)), finalFileExists: nothingOnDisk)
        #expect(tracker.summary == nil)
    }

    /// The summary is quantised to whole percents, so two readings a few
    /// bytes apart compare equal — which is what lets the app skip redrawing
    /// the ring for every chunk a browser writes.
    @Test func readingsInTheSamePercentGiveAnEqualSummary() {
        var a = DownloadTracker(), b = DownloadTracker()
        let id = DownloadID()
        a.apply(.published(id, reading("a.download", 4_200, of: 10_000)), finalFileExists: nothingOnDisk)
        b.apply(.published(id, reading("a.download", 4_299, of: 10_000)), finalFileExists: nothingOnDisk)
        #expect(a.summary == b.summary)
    }

    // MARK: - Completion

    @Test func aDownloadThatReachedItsTotalCompletesWhenUnpublished() throws {
        var tracker = DownloadTracker()
        let id = DownloadID()
        tracker.apply(.published(id, reading("report.pdf.download", 0, of: 1000)), finalFileExists: nothingOnDisk)
        #expect(tracker.apply(.changed(id, reading("report.pdf.download", 1000, of: 1000)),
                              finalFileExists: nothingOnDisk) == nil)

        let completion = tracker.apply(.unpublished(id), finalFileExists: nothingOnDisk)
        let done = try #require(completion)
        #expect(done.name == "report.pdf")
        #expect(done.url == downloads.appendingPathComponent("report.pdf"))
        #expect(done.text == "Downloaded report.pdf")
        #expect(tracker.summary == nil)
    }

    /// Browsers do not always publish the last chunk before unpublishing. A
    /// partial file that has been renamed to its final name has finished,
    /// whatever the last reading said.
    @Test func aRenamedPartialFileCompletesEvenShortOfItsTotal() throws {
        var tracker = DownloadTracker()
        let id = DownloadID()
        tracker.apply(.published(id, reading("a.zip.download", 970, of: 1000)), finalFileExists: nothingOnDisk)
        let finalURL = downloads.appendingPathComponent("a.zip")
        let done = tracker.apply(.unpublished(id), finalFileExists: { $0 == finalURL })
        #expect(done?.name == "a.zip")
    }

    /// The fallback means nothing when the progress was published on the
    /// final name itself: that file exists for the whole download, so its
    /// existing says nothing about whether it finished.
    @Test func aFileWithNoPartialExtensionNeedsItsTotalToComplete() {
        var tracker = DownloadTracker()
        let id = DownloadID()
        tracker.apply(.published(id, reading("a.zip", 970, of: 1000)), finalFileExists: nothingOnDisk)
        #expect(tracker.apply(.unpublished(id), finalFileExists: { _ in true }) == nil)
    }

    /// Stopped short with nothing renamed: abandoned, or paused by quitting
    /// the browser. Not a completion.
    @Test func aDownloadUnpublishedShortOfItsTotalDidNotComplete() {
        var tracker = DownloadTracker()
        let id = DownloadID()
        tracker.apply(.published(id, reading("a.zip.download", 500, of: 1000)), finalFileExists: nothingOnDisk)
        #expect(tracker.apply(.unpublished(id), finalFileExists: nothingOnDisk) == nil)
        #expect(tracker.summary == nil)
    }

    @Test func aCancelledDownloadNeverCompletes() {
        var tracker = DownloadTracker()
        let id = DownloadID()
        tracker.apply(.published(id, reading("a.zip.download", 1000, of: 1000, cancelled: true)),
                      finalFileExists: nothingOnDisk)
        #expect(tracker.apply(.unpublished(id), finalFileExists: { _ in true }) == nil)
    }

    @Test func unpublishingSomethingUnknownCompletesNothing() {
        var tracker = DownloadTracker()
        #expect(tracker.apply(.unpublished(DownloadID()), finalFileExists: { _ in true }) == nil)
    }

    @Test func resetForgetsEverything() {
        var tracker = DownloadTracker()
        let id = DownloadID()
        tracker.apply(.published(id, reading("a.download", 1000, of: 1000)), finalFileExists: nothingOnDisk)
        tracker.reset()
        #expect(tracker.summary == nil)
        // And a late unpublish for what was forgotten announces nothing.
        #expect(tracker.apply(.unpublished(id), finalFileExists: nothingOnDisk) == nil)
    }
}
