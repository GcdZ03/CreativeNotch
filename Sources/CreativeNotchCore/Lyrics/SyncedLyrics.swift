import Foundation

/// One line of synced lyrics: when it starts, in seconds into the track,
/// and what is sung. Empty text is an instrumental break.
public struct LyricLine: Equatable, Sendable {
    public let time: TimeInterval
    public let text: String

    public init(time: TimeInterval, text: String) {
        self.time = time
        self.text = text
    }
}

/// The words a lyrics view draws (spec 2026-10-29). What `AppState`
/// holds: a value that changes only when a line does, so publishing an
/// equal one redraws nothing.
public struct LyricsText: Equatable, Sendable {
    /// The line being sung, `""` in a break, `nil` before the first.
    public let current: String?

    public init(current: String?) {
        self.current = current
    }
}

/// What a lyrics view draws at one instant, and when it will next differ.
public struct LyricsFrame: Equatable, Sendable {
    public let text: LyricsText
    /// When `text.current` changes, or `nil` when it never will on its own:
    /// paused, or past the last line. The controller's one-shot sleeps
    /// until exactly this instant.
    public let nextChangeAt: Date?

    public var current: String? { text.current }
}

/// A track's lyrics with a time on every line, parsed from LRC.
///
/// Every question takes the playback position and `now`, like
/// `PlaybackPosition` itself, so nothing here reads a clock and the whole
/// of the syncing arithmetic is testable without waiting for a song.
public struct SyncedLyrics: Equatable, Sendable {
    /// Sorted by time; stable, so lines on one instant keep their order.
    public let lines: [LyricLine]

    public init(lines: [LyricLine]) {
        self.lines = lines.enumerated()
            .sorted { $0.element.time == $1.element.time ? $0.offset < $1.offset : $0.element.time < $1.element.time }
            .map(\.element)
    }

    /// `nil` when nothing in `lrc` has a time: plain lyrics are not synced
    /// lyrics, and showing them as if they were would be wrong on every line.
    public init?(lrc: String) {
        var offset: TimeInterval = 0
        var parsed: [LyricLine] = []
        for raw in lrc.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            var rest = Substring(raw.trimmingCharacters(in: .whitespaces))
            var times: [TimeInterval] = []
            while rest.first == "[", let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                if let time = Self.time(tag) {
                    times.append(time)
                } else if let value = Self.offsetMilliseconds(tag) {
                    offset = value / 1000
                }
                rest = rest[rest.index(after: close)...]
            }
            guard !times.isEmpty else { continue }
            let text = Self.strippingWordTimes(rest).trimmingCharacters(in: .whitespaces)
            parsed += times.map { LyricLine(time: $0, text: text) }
        }
        guard !parsed.isEmpty else { return nil }
        // A positive offset means the lyrics run late, so lines move earlier.
        self.init(lines: parsed.map { LyricLine(time: max($0.time - offset, 0), text: $0.text) })
    }

    // MARK: - Syncing

    /// The line current at `elapsed`, or `nil` before the first. Of lines
    /// sharing an instant, the last wins.
    public func index(at elapsed: TimeInterval) -> Int? {
        // The first line starting after `elapsed`; the one before it is current.
        var low = 0, high = lines.count
        while low < high {
            let mid = (low + high) / 2
            if lines[mid].time <= elapsed { low = mid + 1 } else { high = mid }
        }
        return low == 0 ? nil : low - 1
    }

    /// The first line time strictly after `elapsed`, or `nil` past the last.
    public func nextChange(after elapsed: TimeInterval) -> TimeInterval? {
        let next = (index(at: elapsed) ?? -1) + 1
        return next < lines.count ? lines[next].time : nil
    }

    public func frame(position: PlaybackPosition, isPlaying: Bool, at now: Date) -> LyricsFrame {
        let elapsed = position.elapsed(at: now, isPlaying: isPlaying)
        let current = index(at: elapsed)
        let change = isPlaying ? nextChange(after: elapsed) : nil
        return LyricsFrame(
            text: LyricsText(current: current.map { lines[$0].text }),
            nextChangeAt: change.map { now.addingTimeInterval($0 - elapsed) }
        )
    }

    // MARK: - Long lines (2026-10-29)

    /// Every line `tooLong` says will not fit, split at a natural pause into
    /// two lines of its own, the second timed by the first's share of the
    /// characters -- and split again if a half still does not fit, into at
    /// most four.
    ///
    /// The strip under the notch is one line about as wide as the notch and
    /// its badge; it shrinks a line to 75% and then cuts it with "…". A split
    /// shows the whole line in turn at the cost of one more wake, where
    /// scrolling it would be an animation for the line's length. The second
    /// half's time is an estimate: words are not sung at an even pace.
    ///
    /// Left alone: a line that fits, the last line (nothing says when it
    /// ends), a line or part shorter than `minimumSpan` (no time to read two
    /// halves), and a single unbroken word.
    public func splittingLines(where tooLong: (String) -> Bool) -> SyncedLyrics {
        var split: [LyricLine] = []
        for (i, line) in lines.enumerated() {
            guard i + 1 < lines.count, !line.text.isEmpty else {
                split.append(line)
                continue
            }
            split += Self.split(line.text, from: line.time, to: lines[i + 1].time, depth: 0, tooLong: tooLong)
        }
        return SyncedLyrics(lines: split)
    }

    /// Below this, a line is not split: two halves need a second each.
    public static let minimumSpan: TimeInterval = 2

    private static func split(
        _ text: String, from start: TimeInterval, to end: TimeInterval, depth: Int, tooLong: (String) -> Bool
    ) -> [LyricLine] {
        guard depth < 2, end - start >= minimumSpan, tooLong(text), let at = breakIndex(in: text) else {
            return [LyricLine(time: start, text: text)]
        }
        let first = String(text[..<at]).trimmingCharacters(in: .whitespaces)
        let second = String(text[at...]).trimmingCharacters(in: .whitespaces)
        let share = Double(first.count) / Double(first.count + second.count)
        let middle = start + (end - start) * share
        return split(first, from: start, to: middle, depth: depth + 1, tooLong: tooLong)
            + split(second, from: middle, to: end, depth: depth + 1, tooLong: tooLong)
    }

    /// Where to break: after the pause (`,` `;` `:` `—` `–`) nearest the
    /// middle, if one sits in the middle half of the line; otherwise at the
    /// space nearest the middle. `nil` for a line with no space at all.
    private static func breakIndex(in text: String) -> String.Index? {
        let characters = Array(text)
        let middle = Double(characters.count) / 2
        let spaces = characters.indices.filter { characters[$0] == " " && $0 > 0 && $0 < characters.count - 1 }
        guard !spaces.isEmpty else { return nil }
        let pauses = spaces.filter {
            ",;:—–".contains(characters[$0 - 1])
                && Double($0) >= Double(characters.count) * 0.25
                && Double($0) <= Double(characters.count) * 0.75
        }
        let candidates = pauses.isEmpty ? spaces : pauses
        let best = candidates.min { abs(Double($0) - middle) < abs(Double($1) - middle) }!
        return text.index(text.startIndex, offsetBy: best)
    }

    // MARK: - LRC

    /// `m:ss`, `mm:ss.xx`, `mm:ss.xxx` or `mm:ss:xx` — all four occur.
    private static func time(_ tag: Substring) -> TimeInterval? {
        let parts = tag.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isNumber || $0 == "." } }),
              let minutes = Double(parts[0]), let seconds = Double(parts[1])
        else { return nil }
        var total = minutes * 60 + seconds
        if parts.count == 3, let fraction = Double("0." + parts[2]) { total += fraction }
        return total
    }

    private static func offsetMilliseconds(_ tag: Substring) -> TimeInterval? {
        guard tag.lowercased().hasPrefix("offset:") else { return nil }
        return Double(tag.dropFirst("offset:".count).trimmingCharacters(in: .whitespaces))
    }

    /// Enhanced LRC's `<mm:ss.xx>` word stamps, removed.
    private static func strippingWordTimes(_ text: Substring) -> String {
        var out = ""
        var rest = text
        while let open = rest.firstIndex(of: "<"), let close = rest[open...].firstIndex(of: ">"),
              time(rest[rest.index(after: open)..<close]) != nil {
            out += rest[..<open]
            rest = rest[rest.index(after: close)...]
        }
        return out + rest
    }
}
