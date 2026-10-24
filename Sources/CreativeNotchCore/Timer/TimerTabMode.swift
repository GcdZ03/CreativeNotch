import Foundation

/// The two halves of the timer tab: countdowns, or the stopwatch.
///
/// A switch inside the existing tab rather than a tab of its own. The ear
/// has room for so many icons (`TabVisibility`), and a stopwatch is a timer
/// counting the other way — the same place, the same verbs.
public enum TimerTabMode: String, CaseIterable, Sendable {
    case timer
    case stopwatch

    public var title: String {
        switch self {
        case .timer: return String(localized: "Timer", bundle: .creativeNotch)
        case .stopwatch: return String(localized: "Stopwatch", bundle: .creativeNotch)
        }
    }
}
