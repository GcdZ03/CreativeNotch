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
        switch parts(remaining) {
        case .minutes(let count): return String(localized: "\(count) minutes", bundle: .creativeNotch)
        case .seconds(let count): return String(localized: "\(count) seconds", bundle: .creativeNotch)
        }
    }

    /// The ear badge: the time, and whether it is paused, since dimming is
    /// the only sign of that on screen.
    public static func remaining(_ remaining: TimeInterval, isPaused: Bool) -> String {
        let time = duration(remaining)
        return isPaused
            ? String(localized: "Timer paused, \(time) remaining", bundle: .creativeNotch)
            : String(localized: "\(time) remaining", bundle: .creativeNotch)
    }

    /// The panel's countdown, with the bar folded in: the bar has no words
    /// of its own, and a separate element for it would be one more stop for
    /// a VoiceOver user to pass on the way to Pause.
    ///
    /// `fraction` is `TimerProgress.fraction`, taken at the same `now` as the
    /// digits, so the two halves of the sentence are one reading.
    public static func value(remaining: TimeInterval, isPaused: Bool, fraction: Double) -> String {
        let percent = Int((max(0, min(1, fraction)) * 100).rounded())
        let time = duration(remaining)
        return isPaused
            ? String(localized: "Paused, \(time) remaining, \(percent)% done", bundle: .creativeNotch)
            : String(localized: "\(time) remaining, \(percent)% done", bundle: .creativeNotch)
    }

    /// The completion peek, spoken: "25-minute timer finished", and how
    /// long ago when it fired late.
    ///
    /// Lateness uses `TimerCompletionText`'s floor and units, so the
    /// written and spoken peek never disagree about whether it was late.
    public static func completion(_ completion: TimerCompletion) -> String {
        let finished: String
        switch parts(completion.duration) {
        case .minutes(let count): finished = String(localized: "\(count)-minute timer finished", bundle: .creativeNotch)
        case .seconds(let count): finished = String(localized: "\(count)-second timer finished", bundle: .creativeNotch)
        }
        guard completion.lateness >= TimerCompletionText.latenessFloor else { return finished }

        let minutes = Int(completion.lateness / 60)
        let ago = minutes >= 60
            ? String(localized: "\(minutes / 60) hours", bundle: .creativeNotch)
            : String(localized: "\(minutes) minutes", bundle: .creativeNotch)
        return String(localized: "\(finished) \(ago) ago", bundle: .creativeNotch, comment: "25-minute timer finished, 3 minutes ago")
    }

    /// The display's granularity: ceiling minutes above a minute, seconds
    /// at a minute and below. A case per unit rather than a unit *word*, so
    /// each reading is one whole catalog entry a translator can inflect.
    private enum Parts {
        case minutes(Int)
        case seconds(Int)
    }

    private static func parts(_ remaining: TimeInterval) -> Parts {
        let seconds = Int(ceil(max(0, remaining)))
        if seconds >= 60 { return .minutes((seconds + 59) / 60) }
        return .seconds(seconds)
    }
}
