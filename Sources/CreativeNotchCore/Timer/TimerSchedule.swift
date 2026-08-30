import Foundation

/// When to wake next, and the one place the `SystemActivity` exemption is
/// decided.
///
/// `SystemActivity` suspends the clipboard poller and the media helper
/// wholesale, because nobody is looking at their output. A timer cannot be
/// suspended that way: its whole purpose is to fire while nobody is
/// looking. So the exemption splits, and the split is here rather than in
/// the controller so that it is testable by passing timestamps.
public enum TimerSchedule {

    /// Seconds until the next wake, or `nil` when there is nothing to do.
    ///
    /// - Active: the next *display* change, so the ear stays current.
    /// - Inactive: the deadline only. Intermediate redraws would paint
    ///   against a dark screen.
    ///
    /// Paused timers schedule nothing at all — the display is frozen and
    /// the deadline is not approaching. This is where the spec's claim
    /// that a paused timer redraws zero times actually becomes true;
    /// `TimerDisplay.nextChange` takes a bare `TimeInterval` and
    /// structurally cannot see pause.
    public static func nextWake(
        countdown: Countdown?,
        isActive: Bool,
        at now: Date
    ) -> TimeInterval? {
        guard let countdown, !countdown.isPaused else { return nil }
        let remaining = countdown.remaining(at: now)
        guard remaining > 0 else { return nil }
        guard isActive else { return remaining }
        guard let change = TimerDisplay.nextChange(remaining: remaining) else {
            return remaining
        }
        // The deadline caps the display change: overshooting it would leave
        // the completion unfired until the next redraw that never comes.
        //
        // Belt and braces, not a live branch. `TimerDisplay.nextChange`
        // returns `remaining - boundary` with `boundary >= 0` for every
        // positive `remaining`, so `change <= remaining` already holds and
        // this `min` cannot bind — no test can kill it, and
        // `aWakeIsNeverScheduledPastTheDeadline` pins the property it
        // guards rather than the guard itself. It stays because the cap is
        // this function's contract with the controller, not `nextChange`'s
        // to keep.
        return min(change, remaining)
    }
}
