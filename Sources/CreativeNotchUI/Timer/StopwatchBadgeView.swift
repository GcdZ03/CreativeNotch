import SwiftUI
import CreativeNotchCore

/// A started stopwatch beside the closed notch (2026-10-29): its count in
/// the timer badge's type, with a pause glyph while it is stopped.
///
/// While it runs the digits are a `Text(timerInterval:)` counting up from
/// the stopwatch's anchor, as in the tab: the system moves them, the app
/// schedules nothing. Stopped, they are a plain value. A render that has to
/// be repeatable turns the live count off with `stopwatchCountsLive`.
struct StopwatchBadgeView: View {
    let stopwatch: Stopwatch
    let now: Date

    @Environment(\.stopwatchCountsLive) private var countsLive

    var body: some View {
        HStack(spacing: 2) {
            if !stopwatch.isRunning {
                Image(systemName: "pause.fill")
                    .font(.system(size: 7, weight: .bold))
            }
            digits
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .foregroundStyle(.ink(stopwatch.isRunning ? 0.95 : 0.4))
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Stopwatch", bundle: .creativeNotch))
        .accessibilityValue(StopwatchView.accessibilityValue(stopwatch, at: now))
    }

    private var digits: Text {
        if countsLive, stopwatch.isRunning, let anchor = stopwatch.anchor {
            return Text(timerInterval: anchor...anchor.addingTimeInterval(100 * 3600), countsDown: false)
        }
        return Text(StopwatchDisplay.text(elapsed: stopwatch.elapsed(at: now)))
    }
}
