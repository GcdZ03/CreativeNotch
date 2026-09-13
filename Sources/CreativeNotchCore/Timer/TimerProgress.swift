import Foundation

/// How much of the countdown has elapsed, for the track under the digits.
///
/// A function of the same `now` `TimerDisplay.text` is given, so the track
/// redraws exactly when the digits do and never on a clock of its own
/// (spec §5.7, §9).
///
/// `Countdown.remaining` is deliberately unclamped so a late fire can report
/// how late; the floor here is what keeps the bar from drawing past its own
/// end. There is no ceiling because none is reachable — `remaining` never
/// exceeds `duration` — and mutation testing showed one changed no
/// behaviour, so it went rather than gaining a test that asserted nothing.
public enum TimerProgress {
    public static func fraction(_ countdown: Countdown, at now: Date) -> Double {
        guard countdown.duration > 0 else { return 1 }
        return 1 - max(0, countdown.remaining(at: now)) / countdown.duration
    }
}
