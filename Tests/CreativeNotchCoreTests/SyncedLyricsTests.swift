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

    // MARK: - Splitting long lines (2026-10-29)

    /// "Too long" for these tests: more than 45 characters. The app measures
    /// the strip's real width instead.
    private let tooLong: (String) -> Bool = { $0.count > 45 }

    /// At the comma nearest the middle, and the second half timed by the
    /// first's share of the characters: 40 + 10 × 40/71.
    @Test func aLongLineSplitsAtAPauseTimedByItsShare() throws {
        let lyrics = SyncedLyrics(lines: [
            LyricLine(time: 40, text: "There's more to do, if we can only live, and this is what we get tonight"),
            LyricLine(time: 50, text: "next"),
        ]).splittingLines(where: tooLong)
        #expect(lyrics.lines.map(\.text) == [
            "There's more to do, if we can only live,",
            "and this is what we get tonight",
            "next",
        ])
        #expect(lyrics.lines[0].time == 40)
        let second = lyrics.lines[1].time
        #expect(abs(second - (40 + 10 * 40.0 / 71.0)) < 0.001)
        #expect(lyrics.lines[2].time == 50)
    }

    /// No punctuation near the middle: the space nearest it.
    @Test func withNoPauseItSplitsAtTheMiddleWord() {
        let lyrics = SyncedLyrics(lines: [
            LyricLine(time: 0, text: "one two three four five six seven eight nine ten"),
            LyricLine(time: 10, text: "x"),
        ]).splittingLines(where: tooLong)
        #expect(lyrics.lines.map(\.text) == ["one two three four five", "six seven eight nine ten", "x"])
    }

    /// A comma near an end is no pause worth splitting at: it would leave a
    /// half too long and a half of two words.
    @Test func aPauseNearAnEndIsPassedOver() {
        let lyrics = SyncedLyrics(lines: [
            LyricLine(time: 0, text: "Oh, one two three four five six seven eight nine ten eleven"),
            LyricLine(time: 10, text: "x"),
        ]).splittingLines(where: tooLong)
        #expect(lyrics.lines[0].text != "Oh,")
        #expect(lyrics.lines.count == 3)
    }

    @Test func aLineThatFitsIsLeftAlone() {
        let song = SyncedLyrics(lines: [LyricLine(time: 0, text: "short"), LyricLine(time: 5, text: "")])
        #expect(song.splittingLines(where: tooLong) == song)
    }

    /// The last line has no end to time its second half against.
    @Test func theLastLineIsLeftAlone() {
        let song = SyncedLyrics(lines: [LyricLine(time: 0, text: "one two three four five six seven eight nine ten")])
        #expect(song.splittingLines(where: tooLong) == song)
    }

    /// Under two seconds there is no time to read two halves.
    @Test func aQuickLineIsLeftAlone() {
        let song = SyncedLyrics(lines: [
            LyricLine(time: 0, text: "one two three four five six seven eight nine ten"),
            LyricLine(time: 1.5, text: "x"),
        ])
        #expect(song.splittingLines(where: tooLong) == song)
    }

    /// A line long enough that a half is still too long splits again, into
    /// at most four parts.
    @Test func aVeryLongLineSplitsIntoAtMostFour() {
        let words = (1...40).map { "w\($0)" }.joined(separator: " ")
        let lyrics = SyncedLyrics(lines: [LyricLine(time: 0, text: words), LyricLine(time: 20, text: "x")])
            .splittingLines(where: tooLong)
        #expect(lyrics.lines.count == 5)
        #expect(lyrics.lines.dropLast().map(\.text).joined(separator: " ") == words)
        #expect(lyrics.lines.map(\.time) == lyrics.lines.map(\.time).sorted())
    }

    /// A word with no space in it cannot be split; it is cut as before.
    @Test func oneUnbrokenWordIsLeftAlone() {
        let song = SyncedLyrics(lines: [
            LyricLine(time: 0, text: String(repeating: "a", count: 50)),
            LyricLine(time: 10, text: "x"),
        ])
        #expect(song.splittingLines(where: tooLong) == song)
    }

    /// The halves are ordinary lines: the frame and its one-shot follow them.
    @Test func theOneShotLandsOnTheSecondHalf() throws {
        let lyrics = SyncedLyrics(lines: [
            LyricLine(time: 0, text: "one two three four five six seven eight nine ten"),
            LyricLine(time: 10, text: "x"),
        ]).splittingLines(where: tooLong)
        let position = try #require(PlaybackPosition(elapsed: 1, duration: 200, anchoredAt: t0))
        let frame = lyrics.frame(position: position, isPlaying: true, at: t0)
        #expect(frame.current == "one two three four five")
        #expect(frame.nextChangeAt == t0.addingTimeInterval(lyrics.lines[1].time - 1))
    }

    // MARK: - Chinese and Japanese lines (2026-10-29)

    /// Chinese is written without spaces, so "too long" here is in
    /// characters of its own: more than 12.
    private let tooLongCJK: (String) -> Bool = { $0.count > 12 }

    private func split(_ text: String) -> [String] {
        SyncedLyrics(lines: [LyricLine(time: 0, text: text), LyricLine(time: 10, text: "x")])
            .splittingLines(where: tooLongCJK).lines.dropLast().map(\.text)
    }

    /// After the full-width comma nearest the middle; no space needed.
    @Test func aChineseLineSplitsAfterItsComma() {
        #expect(split("为你翘课的那一天，花落的那一天") == ["为你翘课的那一天，", "花落的那一天"])
        // Three phrases: the comma nearest the middle first, then the half
        // still too long splits at its own.
        #expect(split("为你翘课的那一天，花落的那一天，教室的那一间") == ["为你翘课的那一天，", "花落的那一天，", "教室的那一间"])
    }

    /// No punctuation and no space: Chinese can break between any two
    /// characters, so it breaks at the middle one.
    @Test func aChineseLineWithNoPauseSplitsInTheMiddle() {
        #expect(split("没想到失去的勇气我还留着好想再问一遍") == ["没想到失去的勇气我", "还留着好想再问一遍"])
    }

    /// A space between phrases is the pause, and it wins over the middle
    /// character.
    @Test func aSpaceBetweenChinesePhrasesIsThePause() {
        #expect(split("等到放晴的那天 也许我会比较好一点") == ["等到放晴的那天", "也许我会比较好一点"])
    }

    @Test func japaneseKanaBreaksAnywhereToo() {
        #expect(split("あいうえおかきくけこさしすせそ").count == 2)
    }

    /// Korean is written with spaces between words: it breaks at a space,
    /// never inside a word.
    @Test func koreanBreaksOnlyAtASpace() {
        let parts = split("사랑했지만 그대를 사랑했지만 그저")
        #expect(parts.count == 2)
        #expect(parts.joined(separator: " ") == "사랑했지만 그대를 사랑했지만 그저")
    }

    /// The second half is timed by the characters' share, which for Chinese
    /// is close to the sung syllables': 9 of 18 is halfway.
    @Test func aChineseHalfIsTimedByItsShare() throws {
        let lyrics = SyncedLyrics(lines: [
            LyricLine(time: 0, text: "没想到失去的勇气我还留着好想再问一遍"),
            LyricLine(time: 10, text: "x"),
        ]).splittingLines(where: tooLongCJK)
        #expect(lyrics.lines[1].time == 5)
    }
}
