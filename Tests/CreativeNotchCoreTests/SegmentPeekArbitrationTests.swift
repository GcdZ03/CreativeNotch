import Foundation
import Testing
@testable import CreativeNotchCore

/// What a hover shows when several activities share the notch (2026-10-29):
/// the one under the pointer. Anything unasked -- a finished timer, a power
/// change, a device, a finished download -- still comes first, wherever the
/// pointer is.
struct SegmentPeekArbitrationTests {

    private let playing = TrackSnapshot(title: "Song", artist: "Artist", isPlaying: true)
    private let summary = DownloadSummary(count: 1, percent: 42, leadingName: "a.zip")

    private func arbiter(countdown: Bool = true, stopwatch: Bool = true) -> PeekArbiter {
        var a = PeekArbiter()
        a.setNowPlaying(playing)
        a.setDownloads(summary)
        a.setTimers(countdown: countdown, stopwatch: stopwatch)
        return a
    }

    @Test func overASegmentItsOwnPeekShows() {
        let a = arbiter()
        #expect(a.content(now: 0, over: .nowPlaying) == .nowPlaying(playing))
        #expect(a.content(now: 0, over: .timer) == .timer)
        #expect(a.content(now: 0, over: .stopwatch) == .stopwatch)
        #expect(a.content(now: 0, over: .downloads) == .downloads(summary))
    }

    /// Over the housing, the privacy dot or nowhere in particular: the old
    /// order, downloads before music.
    @Test func elsewhereTheOldOrderStands() {
        let a = arbiter()
        #expect(a.content(now: 0, over: nil) == .downloads(summary))
        #expect(a.content(now: 0, over: .capture) == .downloads(summary))
        #expect(a.content(now: 0) == .downloads(summary))
    }

    /// The timers are never a peek unasked: only a hover over one shows it.
    @Test func aTimerPeekIsOnlyEverAskedFor() {
        var a = PeekArbiter()
        a.setTimers(countdown: true, stopwatch: true)
        #expect(a.content(now: 0) == nil)
        #expect(a.content(now: 0, over: .timer) == .timer)
    }

    /// A segment whose activity has gone falls back to the old order.
    @Test func aGoneActivityFallsBack() {
        let a = arbiter(countdown: false, stopwatch: false)
        #expect(a.content(now: 0, over: .timer) == .downloads(summary))
        #expect(a.content(now: 0, over: .stopwatch) == .downloads(summary))
    }

    /// Unasked news outranks the segment under the pointer.
    @Test func transientPeeksStillComeFirst() {
        var a = arbiter()
        a.recordPower(.pluggedIn(level: 50), now: 0)
        #expect(a.content(now: 1, over: .timer) == .power(.pluggedIn(level: 50)))
    }

    /// A timer peek on screen is held while the pointer is on it, and
    /// changes nothing underneath when the music moves on.
    @Test func aShowingTimerPeekIsHeldUnderThePointer() {
        let a = arbiter()
        #expect(a.content(now: 0, replacing: .timer, pointerInside: true) == .timer)
        #expect(a.content(now: 0, replacing: .stopwatch, pointerInside: true) == .stopwatch)
        #expect(a.content(now: 0, replacing: .timer, pointerInside: false) == nil)
    }

    @Test func theTimerPeeksAreOneRowBelowTheNotch() {
        #expect(NotchState.peek(.timer).presentation == .statusPeek)
        #expect(NotchState.peek(.stopwatch).presentation == .statusPeek)
    }
}
