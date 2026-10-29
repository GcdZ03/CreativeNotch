import Foundation
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// The lyrics controller against a fake service and a pinned clock (spec
/// 2026-10-29): one request per track, one one-shot per line, and nothing
/// at all while the module is off or nobody can see the screen.
@MainActor
struct LyricsControllerTests {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private static let lrc = "[00:10.00] one\n[00:20.00] two\n[00:30.00]\n[00:40.00] four"
    private static let found = #"{"instrumental":false,"syncedLyrics":"[00:10.00] one\n[00:20.00] two\n[00:30.00]\n[00:40.00] four"}"#

    /// Answers from a script, one per request, and records every URL asked.
    /// Never touches the network.
    /// `byTitle` scripts one track's answers apart from the rest, so a test
    /// about two tracks does not depend on which request runs first.
    private final class FakeService: @unchecked Sendable {
        var answers: [(Int, String)?]
        var byTitle: [String: [(Int, String)?]] = [:]
        private(set) var asked: [URL] = []
        init(_ answers: [(Int, String)?]) { self.answers = answers }
        func fetch(_ url: URL) -> (status: Int, body: Data)? {
            asked.append(url)
            let title = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "track_name" }?.value ?? ""
            let answer: (Int, String)??
            if byTitle[title] != nil {
                answer = byTitle[title]!.isEmpty ? nil : byTitle[title]!.removeFirst()
            } else {
                answer = answers.isEmpty ? nil : answers.removeFirst()
            }
            guard let answer, let answer else { return nil }
            return (answer.0, Data(answer.1.utf8))
        }
        func asked(about title: String) -> Int {
            asked.filter {
                URLComponents(url: $0, resolvingAgainstBaseURL: false)?
                    .queryItems?.contains(URLQueryItem(name: "track_name", value: title)) == true
            }.count
        }
    }

    private final class Published {
        var texts: [LyricsText?] = []
        var last: LyricsText? { texts.last ?? nil }
    }

    private struct Rig {
        let controller: LyricsController
        let service: FakeService
        let published: Published
        let log: SleepLog
    }

    /// The sleeper records what it was asked for and parks, so nothing fires
    /// on its own; a test that wants a line to arrive calls `boundaryReached`.
    private func make(_ answers: [(Int, String)?] = [(200, found)], now: Date? = nil) -> Rig {
        let service = FakeService(answers)
        let published = Published()
        let log = SleepLog()
        let controller = LyricsController(fetch: { url in service.fetch(url) })
        let instant = now ?? t0
        controller.now = { instant }
        controller.sleep = { duration in
            await log.record(duration)
            try? await Task.sleep(for: .seconds(86_400 * 365))
        }
        controller.onChange = { published.texts.append($0) }
        return Rig(controller: controller, service: service, published: published, log: log)
    }

    private func track(
        _ title: String = "I Want to Live",
        playing: Bool = true, elapsed: Double = 12, duration: Double? = 233
    ) -> TrackSnapshot {
        TrackSnapshot(
            title: title, artist: "Borislav Slavov", isPlaying: playing,
            position: duration.flatMap { PlaybackPosition(elapsed: elapsed, duration: $0, anchoredAt: t0) }
        )
    }

    /// Lets the lookup task run to its end.
    private func settle(_ rig: Rig) async {
        await rig.controller.lookupTask?.value
    }

    // MARK: - Off means nothing

    @Test func offItAsksNothingAndPublishesNothing() async {
        let rig = make()
        rig.controller.trackDidChange(track())
        await settle(rig)
        #expect(rig.service.asked.isEmpty)
        #expect(rig.published.texts.isEmpty)
        #expect(rig.controller.boundaryTask == nil)
    }

    // MARK: - One request per track

    @Test func aPlayingTrackIsLookedUpOnceAndItsLineShown() async {
        let rig = make()
        rig.controller.setEnabled(true)
        rig.controller.trackDidChange(track())
        await settle(rig)

        #expect(rig.service.asked.count == 1)
        #expect(rig.published.last == LyricsText(current: "one"))
    }

    /// A pause, a seek, a play: the same track, and no second request.
    @Test func playPauseAndSeekNeverAskAgain() async {
        let rig = make()
        rig.controller.setEnabled(true)
        rig.controller.trackDidChange(track())
        await settle(rig)
        rig.controller.trackDidChange(track(playing: false))
        rig.controller.trackDidChange(track(elapsed: 25))
        await settle(rig)

        #expect(rig.service.asked.count == 1)
        #expect(rig.published.last == LyricsText(current: "two"))
    }

    @Test func notFoundIsRememberedAndNeverAskedAgain() async {
        let rig = make([(404, "{}")])
        rig.controller.setEnabled(true)
        rig.controller.trackDidChange(track())
        await settle(rig)
        rig.controller.trackDidChange(track("Other"))
        rig.controller.trackDidChange(track())
        await settle(rig)

        // One for the first track, then the other track's lookup (which the
        // script answers with nothing), and nothing more for the first.
        #expect(rig.service.asked(about: "I Want to Live") == 1)
        #expect(rig.published.last == nil)
    }

    /// `503 ServerOverloaded`: one more try after a pause, then give up for
    /// now -- never a loop.
    @Test func busyIsRetriedOnceAfterAPause() async {
        let rig = make([(503, "{}"), (503, "{}"), (200, Self.found)])
        rig.controller.setEnabled(true)
        rig.controller.trackDidChange(track())
        await rig.log.waitForRequests(1)
        #expect(await rig.log.requests == [LyricsController.retryDelay])
        rig.controller.retryReached()
        await settle(rig)

        #expect(rig.service.asked.count == 2)
        #expect(rig.published.last == nil)
    }

    /// An outage is not an answer about the track, so playing it again asks.
    @Test func anOutageIsNotRemembered() async {
        let rig = make([nil, nil, (200, Self.found)])
        rig.controller.setEnabled(true)
        rig.controller.trackDidChange(track())
        await rig.log.waitForRequests(1)
        rig.controller.retryReached()
        await settle(rig)
        rig.controller.trackDidChange(track("Other", duration: nil))
        rig.controller.trackDidChange(track())
        await settle(rig)

        #expect(rig.service.asked.count == 3)
        #expect(rig.published.last?.current == "one")
    }

    /// No length (a live stream) or nothing to match by: nothing is sent.
    @Test func anUnmatchableTrackIsNeverSent() async {
        let rig = make()
        rig.controller.setEnabled(true)
        rig.controller.trackDidChange(track(duration: nil))
        rig.controller.trackDidChange(track(""))
        await settle(rig)
        #expect(rig.service.asked.isEmpty)
    }

    /// A track that changes before its answer arrives must not show the
    /// old track's lyrics over the new one.
    @Test func aLateAnswerForAnEarlierTrackIsDropped() async {
        let rig = make([(200, Self.found)])
        rig.service.byTitle["Other"] = [(404, "{}")]
        rig.controller.setEnabled(true)
        rig.controller.trackDidChange(track())
        rig.controller.trackDidChange(track("Other"))
        await settle(rig)
        #expect(rig.published.last == nil)
    }

    // MARK: - One one-shot per line

    /// 12s in, the next line is at 20s: one sleep of eight seconds.
    @Test func itSleepsUntilTheNextLineAndNoLonger() async {
        let rig = make()
        rig.controller.setEnabled(true)
        rig.controller.trackDidChange(track())
        await settle(rig)

        await rig.log.waitForRequests(1)
        #expect(await rig.log.requests == [.seconds(8)])
        #expect(rig.controller.scheduledBoundary == t0.addingTimeInterval(8))
    }

    @Test func arrivingAtTheLineShowsItAndSchedulesTheNext() async {
        var clock = t0
        let rig = make()
        rig.controller.now = { clock }
        rig.controller.setEnabled(true)
        rig.controller.trackDidChange(track())
        await settle(rig)

        clock = t0.addingTimeInterval(8)
        rig.controller.boundaryReached()
        #expect(rig.published.last == LyricsText(current: "two"))
        await rig.log.waitForRequests(2)
        #expect(await rig.log.requests.last == .seconds(10))
    }

    /// A one-shot that wakes a hair early must not show the old line again
    /// and schedule a sleep of a few microseconds.
    @Test func anEarlyWakeStillLandsOnTheLine() async {
        var clock = t0
        let rig = make()
        rig.controller.now = { clock }
        rig.controller.setEnabled(true)
        rig.controller.trackDidChange(track())
        await settle(rig)

        clock = t0.addingTimeInterval(7.999)
        rig.controller.boundaryReached()
        #expect(rig.published.last?.current == "two")
    }

    @Test func pausedNothingIsScheduled() async {
        let rig = make()
        rig.controller.setEnabled(true)
        rig.controller.trackDidChange(track(playing: false))
        await settle(rig)
        #expect(rig.published.last?.current == "one")
        #expect(rig.controller.boundaryTask == nil)
    }

    /// The same line republished is not a redraw.
    @Test func anUnchangedLineIsNotRepublished() async {
        let rig = make()
        rig.controller.setEnabled(true)
        rig.controller.trackDidChange(track())
        await settle(rig)
        let count = rig.published.texts.count
        rig.controller.trackDidChange(track(elapsed: 13))
        #expect(rig.published.texts.count == count)
    }

    // MARK: - Nobody looking

    @Test func lockingDropsTheOneShotAndUnlockingRestoresIt() async {
        let rig = make()
        rig.controller.setEnabled(true)
        rig.controller.trackDidChange(track())
        await settle(rig)
        #expect(rig.controller.boundaryTask != nil)

        rig.controller.setActivity(.locked)
        #expect(rig.controller.boundaryTask == nil)

        rig.controller.setActivity(.active)
        #expect(rig.controller.boundaryTask != nil)
    }

    /// A track that starts behind the lock screen is looked up on unlock,
    /// not before.
    @Test func nothingIsAskedWhileLocked() async {
        let rig = make()
        rig.controller.setEnabled(true)
        rig.controller.setActivity(.asleep)
        rig.controller.trackDidChange(track())
        await settle(rig)
        #expect(rig.service.asked.isEmpty)

        rig.controller.setActivity(.active)
        await settle(rig)
        #expect(rig.service.asked.count == 1)
    }

    // MARK: - Switching off

    @Test func switchingOffWithdrawsTheLineAndForgetsEverything() async {
        let rig = make([(200, Self.found), (200, Self.found)])
        rig.controller.setEnabled(true)
        rig.controller.trackDidChange(track())
        await settle(rig)
        #expect(rig.service.asked.count == 1)

        rig.controller.setEnabled(false)
        #expect(rig.published.last == nil)
        #expect(rig.controller.boundaryTask == nil)
        #expect(rig.controller.lookupTask == nil)
        #expect(rig.controller.cachedAnswers == 0)

        // Back on, the track is asked about afresh: the cache went too.
        rig.controller.setEnabled(true)
        await settle(rig)
        #expect(rig.service.asked.count == 2)
    }

    @Test func switchingOffMidRequestPublishesNothingLate() async {
        let rig = make()
        rig.controller.setEnabled(true)
        rig.controller.trackDidChange(track())
        let task = rig.controller.lookupTask
        rig.controller.setEnabled(false)
        await task?.value
        #expect(rig.published.last == nil)
    }

    @Test func nothingPlayingWithdrawsTheLine() async {
        let rig = make()
        rig.controller.setEnabled(true)
        rig.controller.trackDidChange(track())
        await settle(rig)
        rig.controller.trackDidChange(nil)
        #expect(rig.published.last == nil)
        #expect(rig.controller.boundaryTask == nil)
    }
}
