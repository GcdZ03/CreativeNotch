import Foundation

/// One countdown, as a value.
///
/// Stores the `Date` it expires at rather than a tick count, and every
/// answer is derived from that target and a `now` passed in. This is the
/// load-bearing decision of the module: a tick-counting timer loses time
/// across system sleep, because its ticks do not fire while the machine is
/// asleep and it comes back believing it is on schedule. Deriving from a
/// stored target makes sleep a non-event.
///
/// `now` is a parameter for the same reason `PeekArbiter` and
/// `HUDAttribution` take one: it makes the whole lifecycle testable by
/// passing timestamps, with no waiting and no clock to stub.
public struct Countdown: Equatable, Sendable {

    /// Beyond about an hour and a half, a calendar event is the right tool.
    /// The cap also bounds the ear display to three glyphs, which is what
    /// keeps the badge narrow — see `TimerDisplay`.
    public static let maxDuration: TimeInterval = 99 * 60

    /// What was originally set. Kept for the completion peek, which reports
    /// the timer that fired rather than the time remaining (zero).
    public let duration: TimeInterval

    public private(set) var target: Date

    /// The frozen remainder while paused, and the marker that we are.
    ///
    /// A paused timer cannot be represented by the target alone — the
    /// target would keep receding into the past as real time passed.
    public private(set) var pausedRemaining: TimeInterval?

    /// Fails rather than clamping: a caller asking for 200 minutes has a
    /// bug, and silently giving them 99 hides it.
    public init?(duration: TimeInterval, startingAt now: Date) {
        guard duration > 0, duration <= Self.maxDuration else { return nil }
        self.duration = duration
        self.target = now.addingTimeInterval(duration)
        self.pausedRemaining = nil
    }

    public var isPaused: Bool { pausedRemaining != nil }

    /// Deliberately **not** clamped at zero. The completion peek reports how
    /// late it fired when the machine slept through the deadline, and that
    /// number lives here.
    public func remaining(at now: Date) -> TimeInterval {
        if let pausedRemaining { return pausedRemaining }
        return target.timeIntervalSince(now)
    }

    public func hasFinished(at now: Date) -> Bool {
        remaining(at: now) <= 0
    }

    /// Idempotent: pausing an already-paused timer must not re-freeze it at
    /// a later, wrong remainder.
    public func paused(at now: Date) -> Countdown {
        guard !isPaused else { return self }
        var copy = self
        copy.pausedRemaining = remaining(at: now)
        return copy
    }

    public func resumed(at now: Date) -> Countdown {
        guard let pausedRemaining else { return self }
        var copy = self
        copy.target = now.addingTimeInterval(pausedRemaining)
        copy.pausedRemaining = nil
        return copy
    }
}
