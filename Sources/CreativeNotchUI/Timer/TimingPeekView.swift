import SwiftUI
import CreativeNotchCore

/// The one-row peek a hover over the timer's or the stopwatch's segment
/// shows (2026-10-29): what it is, and its time, below the notch like the
/// battery's row.
///
/// Reads the live values the segment reads -- the soonest countdown, how
/// many are running, the stopwatch -- so it ticks with the badge and never
/// shows a stale second. Nothing here schedules anything: the countdown's
/// redraws are the timer's own, and the stopwatch counts in the system's
/// `Text(timerInterval:)`.
struct TimingPeekView: View {
    enum Content: Equatable {
        case countdown(Countdown, count: Int)
        case stopwatch(Stopwatch)
    }

    let content: Content
    let now: Date
    var bandHeight: CGFloat = 32

    @Environment(\.stopwatchCountsLive) private var countsLive

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: bandHeight)
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.ink(0.9))
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.ink(0.95))
                    .lineLimit(1)
                if isPaused {
                    Text("paused", bundle: .creativeNotch)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.ink(0.5))
                        .fixedSize()
                }
                Spacer(minLength: 8)
                time
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.ink(isPaused ? 0.5 : 0.95))
                    .fixedSize()
            }
            .padding(.horizontal, 14)
            .frame(maxHeight: .infinity)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var symbol: String {
        switch content {
        case .countdown: return "timer"
        case .stopwatch: return "stopwatch"
        }
    }

    var title: String {
        switch content {
        case .countdown(_, let count) where count > 1:
            return String(localized: "\(count) timers", bundle: .creativeNotch, comment: "Timer peek: how many countdowns are running")
        case .countdown:
            return String(localized: "Timer", bundle: .creativeNotch)
        case .stopwatch:
            return String(localized: "Stopwatch", bundle: .creativeNotch)
        }
    }

    private var isPaused: Bool {
        switch content {
        case .countdown(let countdown, _): return countdown.isPaused
        case .stopwatch(let stopwatch):    return !stopwatch.isRunning
        }
    }

    private var time: Text {
        switch content {
        case .countdown(let countdown, _):
            return Text(TimerDisplay.text(remaining: countdown.remaining(at: now)))
        case .stopwatch(let stopwatch):
            if countsLive, stopwatch.isRunning, let anchor = stopwatch.anchor {
                return Text(timerInterval: anchor...anchor.addingTimeInterval(100 * 3600), countsDown: false)
            }
            return Text(StopwatchDisplay.text(elapsed: stopwatch.elapsed(at: now)))
        }
    }

    var accessibilityText: String {
        switch content {
        case .countdown(let countdown, _):
            return [title, TimerSpokenText.remaining(countdown.remaining(at: now), isPaused: countdown.isPaused)]
                .joined(separator: ", ")
        case .stopwatch(let stopwatch):
            return [title, StopwatchView.accessibilityValue(stopwatch, at: now)].joined(separator: ", ")
        }
    }
}
