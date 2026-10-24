import Foundation

/// A stopwatch, as a value: dates, never ticks.
///
/// The same decision `Countdown` makes, for the same reason. A stopwatch
/// that counted ticks would lose time across system sleep and would need
/// something waking every second to do the counting. This stores the
/// instant it was last started and what it had banked before that, and
/// every reading is derived from those and a `now` passed in — so a
/// running stopwatch costs nothing at all while nobody is looking at it,
/// and sleep is a non-event.
///
/// There is no scheduler anywhere behind it. While the timer tab is on
/// screen the digits are a `Text(timerInterval:)` counting from `anchor`,
/// which the system keeps current without this app waking; off screen
/// there is nothing to draw and nothing runs.
public struct Stopwatch: Equatable, Sendable {

    /// Enough for any real session of laps, and a bound on a list that
    /// would otherwise grow for as long as someone kept clicking.
    public static let maxLaps = 99

    /// When the current run began, or `nil` while stopped.
    public private(set) var startedAt: Date?

    /// Elapsed time from earlier runs, before the last pause.
    public private(set) var banked: TimeInterval = 0

    /// Each lap's own length (a split), oldest first.
    public private(set) var laps: [TimeInterval] = []

    public init() {}

    public var isRunning: Bool { startedAt != nil }

    /// Nothing to show and nothing to reset: the state Reset returns to.
    public var isReset: Bool { startedAt == nil && banked == 0 && laps.isEmpty }

    /// Floored at what was banked: a clock set backwards must not read
    /// negative time, or less than the stopwatch already showed.
    public func elapsed(at now: Date) -> TimeInterval {
        guard let startedAt else { return banked }
        return banked + max(0, now.timeIntervalSince(startedAt))
    }

    /// The instant the stopwatch would have started had it never paused,
    /// or `nil` while stopped. The lower bound a live
    /// `Text(timerInterval:)` counts up from.
    public var anchor: Date? {
        startedAt?.addingTimeInterval(-banked)
    }

    /// The lap in progress: elapsed time since the last lap mark.
    public func currentLap(at now: Date) -> TimeInterval {
        elapsed(at: now) - laps.reduce(0, +)
    }

    /// Idempotent: starting a running stopwatch does not restart it — a
    /// double click is not a reset.
    public func started(at now: Date) -> Stopwatch {
        guard !isRunning else { return self }
        var copy = self
        copy.startedAt = now
        return copy
    }

    /// Idempotent, like `Countdown.paused`.
    public func paused(at now: Date) -> Stopwatch {
        guard isRunning else { return self }
        var copy = self
        copy.banked = elapsed(at: now)
        copy.startedAt = nil
        return copy
    }

    /// Marks a lap. Only while running: paused, the button beside Resume
    /// reads Reset, and a lap there would be a split of nothing.
    public func lapped(at now: Date) -> Stopwatch {
        guard isRunning, laps.count < Self.maxLaps else { return self }
        var copy = self
        copy.laps.append(currentLap(at: now))
        return copy
    }

    public func reset() -> Stopwatch { Stopwatch() }
}

/// What the stopwatch tab's buttons ask for. One verb through `AppState`
/// rather than four closures, applied at the caller's `now`.
public enum StopwatchCommand: Sendable, Equatable {
    case start, pause, lap, reset
}

extension Stopwatch {
    public func applying(_ command: StopwatchCommand, at now: Date) -> Stopwatch {
        switch command {
        case .start: return started(at: now)
        case .pause: return paused(at: now)
        case .lap:   return lapped(at: now)
        case .reset: return reset()
        }
    }
}

/// What the stopwatch reads, written and spoken.
public enum StopwatchDisplay {

    /// `m:ss` below an hour, `h:mm:ss` from it, whole seconds rounded down.
    ///
    /// That is what `Text(timerInterval:showsHours: true)` draws while the
    /// stopwatch runs, so the frozen text of a paused stopwatch and the
    /// live count read alike and nothing jumps on pause.
    public static func text(elapsed: TimeInterval) -> String {
        let whole = max(0, Int(elapsed.rounded(.down)))
        let h = whole / 3600, m = whole / 60 % 60, s = whole % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    /// The same reading in words: `1:05` aloud is a time of day.
    public static func spoken(elapsed: TimeInterval) -> String {
        let whole = max(0, Int(elapsed.rounded(.down)))
        let h = whole / 3600, m = whole / 60 % 60, s = whole % 60
        var parts: [String] = []
        if h > 0 { parts.append(plural(h, "hour")) }
        if m > 0 { parts.append(plural(m, "minute")) }
        if s > 0 || parts.isEmpty { parts.append(plural(s, "second")) }
        return parts.joined(separator: " ")
    }

    /// One lap as the tab shows it: its number as taken, and its split.
    public struct Lap: Equatable, Sendable {
        public let number: Int
        public let text: String
    }

    /// The newest `limit` laps, newest first. The tab has one line for
    /// laps; the most recent are the ones being compared.
    public static func recentLaps(_ laps: [TimeInterval], limit: Int) -> [Lap] {
        laps.enumerated().reversed().prefix(limit).map {
            Lap(number: $0.offset + 1, text: text(elapsed: $0.element))
        }
    }

    private static func plural(_ count: Int, _ unit: String) -> String {
        "\(count) \(unit)\(count == 1 ? "" : "s")"
    }
}
