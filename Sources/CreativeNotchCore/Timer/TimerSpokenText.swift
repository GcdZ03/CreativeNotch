import Foundation

/// What VoiceOver hears for the timer, where the screen shows `25m`, `0:42`
/// and a bar.
///
/// The written forms are built for a 44pt ear and read badly aloud — `25m`
/// is spelled "25 m", and `0:42` as a time of day. This is the same reading
/// in words, kept beside `TimerDisplay` and `TimerCompletionText` so the
/// two cannot drift apart.
///
/// **Every reading is at the display's own granularity, on purpose.** The
/// countdown redraws only when `TimerDisplay.text` changes — once a minute
/// above a minute (`TimerDisplay.nextChange`) — and an accessibility value
/// is only as fresh as the last redraw. A seconds-precise "4 minutes 12
/// seconds" would be up to a minute stale by the time VoiceOver read it,
/// and making it fresh would mean redrawing every second, which is the cost
/// that schedule exists to avoid. Matching the digits keeps what is heard
/// true whenever it is heard, and keeps VoiceOver from being handed a new
/// value any more often than the screen is.
public enum TimerSpokenText {

    /// Ceiling minutes above a minute, seconds at a minute and below —
    /// `TimerDisplay.text`'s rule, in words.
    public static func duration(_ remaining: TimeInterval) -> String {
        let (count, unit) = parts(remaining)
        return "\(count) \(unit)\(count == 1 ? "" : "s")"
    }

    /// The ear badge: the time, and whether it is paused, since dimming is
    /// the only sign of that on screen.
    public static func remaining(_ remaining: TimeInterval, isPaused: Bool) -> String {
        let left = "\(duration(remaining)) remaining"
        return isPaused ? "Timer paused, \(left)" : left
    }

    /// The panel's countdown, with the bar folded in: the bar has no words
    /// of its own, and a separate element for it would be one more stop for
    /// a VoiceOver user to pass on the way to Pause.
    ///
    /// `fraction` is `TimerProgress.fraction`, taken at the same `now` as the
    /// digits, so the two halves of the sentence are one reading.
    public static func value(remaining: TimeInterval, isPaused: Bool, fraction: Double) -> String {
        let percent = Int((max(0, min(1, fraction)) * 100).rounded())
        let left = "\(duration(remaining)) remaining, \(percent)% done"
        return isPaused ? "Paused, \(left)" : left
    }

    /// The completion peek, spoken: "25-minute timer finished", and how
    /// long ago when it fired late.
    ///
    /// Lateness uses `TimerCompletionText`'s floor and units, so the
    /// written and spoken peek never disagree about whether it was late.
    public static func completion(_ completion: TimerCompletion) -> String {
        let (count, unit) = parts(completion.duration)
        let finished = "\(count)-\(unit) timer finished"
        guard completion.lateness >= TimerCompletionText.latenessFloor else { return finished }

        let minutes = Int(completion.lateness / 60)
        let ago = minutes >= 60 ? plural(minutes / 60, "hour") : plural(minutes, "minute")
        return "\(finished) \(ago) ago"
    }

    private static func parts(_ remaining: TimeInterval) -> (Int, String) {
        let seconds = Int(ceil(max(0, remaining)))
        if seconds >= 60 { return ((seconds + 59) / 60, "minute") }
        return (seconds, "second")
    }

    private static func plural(_ count: Int, _ unit: String) -> String {
        "\(count) \(unit)\(count == 1 ? "" : "s")"
    }
}
