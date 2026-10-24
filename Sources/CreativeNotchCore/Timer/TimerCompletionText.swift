import Foundation

/// What the completion peek says.
///
/// Pure, and in Core, so the lateness wording is testable without
/// rendering — the same split `NowPlayingLabel` uses.
public enum TimerCompletionText {

    /// Below a minute is scheduler jitter rather than lateness, and saying
    /// "finished 12s ago" about a timer that just fired reads as noise.
    /// Internal rather than private because `TimerSpokenText` applies the
    /// same floor: the spoken and written peek must agree on "late".
    static let latenessFloor: TimeInterval = 60

    public static func detail(for completion: TimerCompletion) -> String {
        let duration = TimerDisplay.text(remaining: completion.duration)
        guard completion.lateness >= latenessFloor else { return duration }

        let minutes = Int(completion.lateness / 60)
        let ago = minutes >= 60
            ? String(localized: "\(minutes / 60)h", bundle: .creativeNotch, comment: "Hours, abbreviated")
            : String(localized: "\(minutes)m", bundle: .creativeNotch, comment: "Minutes left, abbreviated to fit the notch")
        return String(localized: "\(duration) · finished \(ago) ago", bundle: .creativeNotch, comment: "Timer peek: 25m · finished 3m ago")
    }
}
