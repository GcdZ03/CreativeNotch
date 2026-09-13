import Foundation

/// How much of the countdown has elapsed, for the track under the digits.
///
/// A function of the same `now` `TimerDisplay.text` is given, so the track
/// redraws exactly when the digits do and never on a clock of its own
/// (spec §5.7, §9). Clamped: `Countdown.remaining` is deliberately
/// unclamped so a late fire can report how late, and a bar drawn past its
/// own end would be the wrong place to show that.
public enum TimerProgress {
    public static func fraction(_ countdown: Countdown, at now: Date) -> Double {
        guard countdown.duration > 0 else { return 1 }
        let remaining = max(0, countdown.remaining(at: now))
        return min(1, max(0, 1 - remaining / countdown.duration))
    }
}
