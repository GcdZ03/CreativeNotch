import Foundation
import Testing
@testable import CreativeNotchCore

/// LRC parsing and the arithmetic that keeps lyrics in time without a clock
/// (spec 2026-10-29).
struct SyncedLyricsTests {

    // MARK: - Parsing

    @Test func parsesTimedLinesInOrder() throws {
        let lyrics = try #require(SyncedLyrics(lrc: """
        [00:17.12] I feel your breath upon my neck
        [00:20.41] A soft caress as cold as death
        """))
        #expect(lyrics.lines == [
            LyricLine(time: 17.12, text: "I feel your breath upon my neck"),
            LyricLine(time: 20.41, text: "A soft caress as cold as death"),
        ])
    }

    /// LRCLIB ends a song with a bare tag: the moment the singing stops.
    @Test func aBareTagIsAnInstrumentalBreak() throws {
        let lyrics = try #require(SyncedLyrics(lrc: "[00:01.00] One\n[00:05.00]"))
        #expect(lyrics.lines.last == LyricLine(time: 5, text: ""))
    }

    @Test func oneLineCanCarrySeveralTimes() throws {
        let lyrics = try #require(SyncedLyrics(lrc: "[00:30.00][00:10.00] Chorus\n[00:20.00] Verse"))
        #expect(lyrics.lines.map(\.time) == [10, 20, 30])
        #expect(lyrics.lines.map(\.text) == ["Chorus", "Verse", "Chorus"])
    }

    @Test func acceptsTheTimeFormatsInTheWild() throws {
        let lyrics = try #require(SyncedLyrics(lrc: "[1:02] a\n[01:03.5] b\n[01:04.123] c\n[01:05:50] d"))
        #expect(lyrics.lines.map(\.time) == [62, 63.5, 64.123, 65.5])
    }

    /// `[ar:]`, `[ti:]` and friends are metadata, not lines.
    @Test func metadataTagsAreNotLines() throws {
        let lyrics = try #require(SyncedLyrics(lrc: "[ar:Someone]\n[ti:Something]\n[length: 03:20]\n[00:01.00] Hello"))
        #expect(lyrics.lines == [LyricLine(time: 1, text: "Hello")])
    }

    /// `[offset:+500]` means the lyrics are 500ms late: every line moves
    /// earlier by that much.
    @Test func theOffsetTagShiftsEveryLine() throws {
        let lyrics = try #require(SyncedLyrics(lrc: "[offset:+500]\n[00:10.00] a\n[00:20.00] b"))
        #expect(lyrics.lines.map(\.time) == [9.5, 19.5])
    }

    /// Word-level ("enhanced") LRC keeps its words and loses its timing.
    @Test func wordTimingIsStripped() throws {
        let lyrics = try #require(SyncedLyrics(lrc: "[00:01.00] <00:01.00>Hello <00:01.50>there"))
        #expect(lyrics.lines.first?.text == "Hello there")
    }

    @Test func plainTextIsNotSyncedLyrics() {
        #expect(SyncedLyrics(lrc: "Just words\nNo times") == nil)
        #expect(SyncedLyrics(lrc: "") == nil)
    }

    @Test func windowsLineEndingsAndStrayWhitespace() throws {
        let lyrics = try #require(SyncedLyrics(lrc: "  [00:01.00]   Hello  \r\n[00:02.00] World\r\n"))
        #expect(lyrics.lines.map(\.text) == ["Hello", "World"])
    }

    // MARK: - Which line, and when the next

    private let song = SyncedLyrics(lines: [
        LyricLine(time: 10, text: "one"),
        LyricLine(time: 20, text: "two"),
        LyricLine(time: 30, text: ""),
        LyricLine(time: 40, text: "four"),
    ])

    @Test func beforeTheFirstLineThereIsNone() {
        #expect(song.index(at: 0) == nil)
        #expect(song.index(at: 9.99) == nil)
    }

    @Test func aLineIsCurrentFromItsTimeUntilTheNext() {
        #expect(song.index(at: 10) == 0)
        #expect(song.index(at: 19.99) == 0)
        #expect(song.index(at: 20) == 1)
        #expect(song.index(at: 35) == 2)
        #expect(song.index(at: 999) == 3)
    }

    @Test func theNextChangeIsTheNextLinesTime() {
        #expect(song.nextChange(after: 0) == 10)
        #expect(song.nextChange(after: 10) == 20)
        #expect(song.nextChange(after: 15) == 20)
        #expect(song.nextChange(after: 40) == nil)
    }

    /// Two lines on one instant (a duplicated tag) change once, not twice.
    @Test func linesOnTheSameInstantChangeOnce() {
        let lyrics = SyncedLyrics(lines: [LyricLine(time: 5, text: "a"), LyricLine(time: 5, text: "b"), LyricLine(time: 9, text: "c")])
        #expect(lyrics.index(at: 5) == 1)
        #expect(lyrics.nextChange(after: 0) == 5)
        #expect(lyrics.nextChange(after: 5) == 9)
    }

    // MARK: - The frame a view draws

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func aFrameNamesTheLineAndWhenItChanges() throws {
        let position = try #require(PlaybackPosition(elapsed: 12, duration: 200, anchoredAt: t0))
        let frame = song.frame(position: position, isPlaying: true, at: t0.addingTimeInterval(3))
        #expect(frame.current == "one")
        // 15s in, the next line is at 20s: five seconds from now.
        #expect(frame.nextChangeAt == t0.addingTimeInterval(8))
    }

    /// Paused, nothing changes on its own, so nothing is scheduled.
    @Test func pausedThereIsNoNextChange() throws {
        let position = try #require(PlaybackPosition(elapsed: 12, duration: 200, anchoredAt: t0))
        let frame = song.frame(position: position, isPlaying: false, at: t0.addingTimeInterval(60))
        #expect(frame.current == "one")
        #expect(frame.nextChangeAt == nil)
    }

    @Test func beforeTheFirstLineTheFrameWaitsForIt() throws {
        let position = try #require(PlaybackPosition(elapsed: 2, duration: 200, anchoredAt: t0))
        let frame = song.frame(position: position, isPlaying: true, at: t0)
        #expect(frame.current == nil)
        #expect(frame.nextChangeAt == t0.addingTimeInterval(8))
    }

    @Test func afterTheLastLineNothingIsScheduled() throws {
        let position = try #require(PlaybackPosition(elapsed: 41, duration: 200, anchoredAt: t0))
        let frame = song.frame(position: position, isPlaying: true, at: t0)
        #expect(frame.current == "four")
        #expect(frame.nextChangeAt == nil)
    }

    /// A break is a line of its own: the change into it is scheduled like
    /// any other.
    @Test func aBreakIsItsOwnChange() throws {
        let position = try #require(PlaybackPosition(elapsed: 25, duration: 200, anchoredAt: t0))
        let frame = song.frame(position: position, isPlaying: true, at: t0)
        #expect(frame.current == "two")
        #expect(frame.nextChangeAt == t0.addingTimeInterval(5))
        let inBreak = song.frame(position: position, isPlaying: true, at: t0.addingTimeInterval(6))
        #expect(inBreak.current == "")
    }
}
