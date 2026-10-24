import Foundation
import Testing
@testable import CreativeNotchCore

/// The stopwatch is dates, never ticks: every reading here is taken by
/// passing a fixed timestamp, so nothing sleeps and nothing waits.
struct StopwatchTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    @Test func aNewStopwatchReadsZeroAndIsReset() {
        let w = Stopwatch()
        #expect(w.elapsed(at: t0) == 0)
        #expect(!w.isRunning)
        #expect(w.isReset)
        #expect(w.anchor == nil)
    }

    @Test func runningElapsedIsDerivedFromTheStartDate() {
        let w = Stopwatch().started(at: t0)
        #expect(w.isRunning)
        #expect(!w.isReset)
        #expect(w.elapsed(at: at(90)) == 90)
        // Sleep is a non-event: an hour later the reading is an hour on.
        #expect(w.elapsed(at: at(3690)) == 3690)
    }

    @Test func pausingFreezesTheReadingAndResumingCarriesOn() {
        let paused = Stopwatch().started(at: t0).paused(at: at(30))
        #expect(!paused.isRunning)
        #expect(paused.elapsed(at: at(5000)) == 30)

        let resumed = paused.started(at: at(100))
        #expect(resumed.elapsed(at: at(110)) == 40)
    }

    /// Starting a running stopwatch, or pausing a paused one, must not move
    /// the reading — a double click is not a restart.
    @Test func startAndPauseAreIdempotent() {
        let running = Stopwatch().started(at: t0)
        #expect(running.started(at: at(50)).elapsed(at: at(60)) == 60)

        let paused = running.paused(at: at(10))
        #expect(paused.paused(at: at(99)).elapsed(at: at(200)) == 10)
    }

    /// A clock set backwards must not read negative time.
    @Test func aClockSetBackwardsReadsNoLessThanWhatWasBanked() {
        let w = Stopwatch().started(at: t0).paused(at: at(20)).started(at: at(100))
        #expect(w.elapsed(at: at(50)) == 20)
    }

    /// The anchor is the instant the stopwatch would have started had it
    /// never paused — the lower bound a live `Text(timerInterval:)` counts
    /// from, so the system keeps the digits current with no clock of ours.
    @Test func theAnchorIsNowMinusElapsedWhileRunning() throws {
        let w = Stopwatch().started(at: t0).paused(at: at(30)).started(at: at(100))
        let anchor = try #require(w.anchor)
        #expect(at(130).timeIntervalSince(anchor) == w.elapsed(at: at(130)))
        #expect(w.paused(at: at(140)).anchor == nil)
    }

    @Test func lapsRecordSplitsNewestLast() {
        var w = Stopwatch().started(at: t0)
        w = w.lapped(at: at(42))
        w = w.lapped(at: at(107))
        #expect(w.laps == [42, 65])
        #expect(w.currentLap(at: at(120)) == 13)
    }

    /// A lap is a mark on a running stopwatch. Paused, the button reads
    /// Reset instead, so a lap there would be a split of zero.
    @Test func lappingAPausedStopwatchDoesNothing() {
        let paused = Stopwatch().started(at: t0).paused(at: at(10))
        #expect(paused.lapped(at: at(20)).laps.isEmpty)
    }

    @Test func lapsAreCappedSoTheListCannotGrowWithoutBound() {
        var w = Stopwatch().started(at: t0)
        for i in 1...(Stopwatch.maxLaps + 5) { w = w.lapped(at: at(TimeInterval(i))) }
        #expect(w.laps.count == Stopwatch.maxLaps)
    }

    @Test func resetClearsEverything() {
        let w = Stopwatch().started(at: t0).lapped(at: at(5)).paused(at: at(9)).reset()
        #expect(w == Stopwatch())
        #expect(w.isReset)
    }

    @Test func commandsMapOntoTheVerbs() {
        var w = Stopwatch().applying(.start, at: t0)
        #expect(w.isRunning)
        w = w.applying(.lap, at: at(12))
        #expect(w.laps == [12])
        w = w.applying(.pause, at: at(20))
        #expect(w.elapsed(at: at(99)) == 20)
        w = w.applying(.reset, at: at(30))
        #expect(w.isReset)
    }

    // MARK: - Display

    /// `m:ss` below an hour, `h:mm:ss` from it, whole seconds rounded
    /// down — what `Text(timerInterval:showsHours: true)` draws while it
    /// runs, so the paused text and the running count read alike.
    @Test func theDisplayMatchesTheLiveTimerText() {
        #expect(StopwatchDisplay.text(elapsed: 0) == "0:00")
        #expect(StopwatchDisplay.text(elapsed: 9.99) == "0:09")
        #expect(StopwatchDisplay.text(elapsed: 65) == "1:05")
        #expect(StopwatchDisplay.text(elapsed: 3599) == "59:59")
        #expect(StopwatchDisplay.text(elapsed: 3600) == "1:00:00")
        #expect(StopwatchDisplay.text(elapsed: 3725) == "1:02:05")
        #expect(StopwatchDisplay.text(elapsed: -4) == "0:00")
    }

    @Test func theSpokenFormIsWords() {
        #expect(StopwatchDisplay.spoken(elapsed: 0) == "0 seconds")
        #expect(StopwatchDisplay.spoken(elapsed: 1) == "1 second")
        #expect(StopwatchDisplay.spoken(elapsed: 65) == "1 minute 5 seconds")
        #expect(StopwatchDisplay.spoken(elapsed: 120) == "2 minutes")
        #expect(StopwatchDisplay.spoken(elapsed: 3725) == "1 hour 2 minutes 5 seconds")
    }

    /// The newest laps first, numbered as they were taken, and no more than
    /// the line has room for.
    @Test func theLapLineShowsTheNewestFew() {
        let lines = StopwatchDisplay.recentLaps([42, 65, 58, 61], limit: 3)
        #expect(lines.map(\.number) == [4, 3, 2])
        #expect(lines.map(\.text) == ["1:01", "0:58", "1:05"])
    }
}
