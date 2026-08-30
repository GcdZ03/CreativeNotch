import Foundation

/// What the countdown reads, and when that reading next changes.
///
/// These are one concern, not two: the display granularity *is* the redraw
/// schedule. A `mm:ss` display costs 1,500 redraws over a 25-minute timer
/// and 5,940 at the 99-minute maximum, each waking the CPU and keeping it
/// out of deeper idle states — the exact cost this project exists to avoid.
/// Showing minutes above a minute costs 25.
///
/// `nextChange` is what makes that saving real: the scheduler asks for the
/// instant the text next differs and sleeps until then, rather than ticking
/// every second and discarding identical frames.
public enum TimerDisplay {

    /// The widest string the format can produce, for sizing the badge once
    /// rather than resizing it as digits drop. `"99m"` and `"0:00"` are
    /// four and three characters; the seconds form is the wider.
    public static let widestText = "0:00"

    /// Ceiling minutes above a minute, `0:SS` at a minute and below.
    ///
    /// Ceiling matters: a 25-minute timer must read `25m` when it starts,
    /// and `floor` would show `24m` immediately.
    public static func text(remaining: TimeInterval) -> String {
        let seconds = Int(ceil(max(0, remaining)))
        if seconds >= 60 {
            // Integer ceiling division.
            return "\((seconds + 59) / 60)m"
        }
        return String(format: "0:%02d", seconds)
    }

    /// How long until `text` returns something different, or `nil` when the
    /// timer has finished and there is nothing left to schedule.
    ///
    /// Returning a delay for a finished timer would keep the machine waking
    /// forever, which is the failure this whole design is built to avoid.
    public static func nextChange(remaining: TimeInterval) -> TimeInterval? {
        guard remaining > 0 else { return nil }
        let seconds = Int(ceil(remaining))

        // The `seconds` value at which the string next differs.
        let boundary: Int
        if seconds >= 60 {
            let minutes = (seconds + 59) / 60
            // `max(59, …)` handles the handover: at 60s the text is "1m",
            // and it changes when seconds take over at 59 — one second
            // away, not sixty. Without this the last minute of every timer
            // would display "1m" frozen while the seconds ran out.
            boundary = max(59, (minutes - 1) * 60)
        } else {
            boundary = seconds - 1
        }

        return remaining - TimeInterval(boundary)
    }
}
