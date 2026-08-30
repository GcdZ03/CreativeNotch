import Foundation

/// What the completion peek says.
///
/// Pure, and in Core, so the lateness wording is testable without
/// rendering — the same split `NowPlayingLabel` uses.
public enum TimerCompletionText {

    /// Below a minute is scheduler jitter rather than lateness, and saying
    /// "finished 12s ago" about a timer that just fired reads as noise.
    private static let latenessFloor: TimeInterval = 60

    public static func detail(for completion: TimerCompletion) -> String {
        let duration = TimerDisplay.text(remaining: completion.duration)
        guard completion.lateness >= latenessFloor else { return duration }

        let minutes = Int(completion.lateness / 60)
        let ago = minutes >= 60 ? "\(minutes / 60)h" : "\(minutes)m"
        return "\(duration) · finished \(ago) ago"
    }
}
