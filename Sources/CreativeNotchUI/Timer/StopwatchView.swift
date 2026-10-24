import SwiftUI
import CreativeNotchCore

/// The stopwatch half of the timer tab (2026-10-24): the elapsed time, the
/// latest laps, and Start, or Lap and Pause, or Reset and Resume.
///
/// **No clock in this view, and none behind it.** The UI bans
/// `TimelineView`, and a stopwatch that redrew itself every second would be
/// exactly the steady cost the notch is built to avoid. While it runs the
/// digits are a `Text(timerInterval:)` counting up from
/// `Stopwatch.anchor`, which the system keeps current without this view
/// re-evaluating or this app waking — the same thing the music peek's times
/// do (`PlaybackProgressView`). It exists only while the timer tab is on
/// screen; the moment the panel closes there is no view, no text and no
/// count, and the stopwatch is two numbers in `AppState` until it is looked
/// at again.
///
/// Paused or reset, the digits are plain text from `StopwatchDisplay`, in
/// the format the live text uses, so pausing does not make them jump.
///
/// The buttons follow the iPhone's: Lap beside Pause while running, Reset
/// beside Resume while paused — so the lap and reset verbs share a place
/// and a lap can never be taken on a stopped watch.
struct StopwatchView: View {
    let stopwatch: Stopwatch
    let now: Date
    var onCommand: (StopwatchCommand) -> Void

    /// Off only where a render must be repeatable: a live
    /// `Text(timerInterval:)` draws whatever the wall clock says.
    @Environment(\.stopwatchCountsLive) private var countsLive

    /// How many laps the one line under the digits has room for.
    static let visibleLaps = 3

    /// Dimmed while paused, like the countdown's digits, and said in words
    /// beside them (`caption`), for anyone two greys do not separate.
    static func digitsOpacity(isPaused: Bool) -> Double {
        TimerTabView.digitsOpacity(isPaused: isPaused)
    }

    /// "paused" beside stopped-but-not-reset digits, nothing otherwise: a
    /// running count says it is running by moving.
    static func caption(_ stopwatch: Stopwatch) -> String? {
        !stopwatch.isRunning && !stopwatch.isReset ? String(localized: "paused", bundle: .creativeNotch) : nil
    }

    /// What VoiceOver reads for a stopped stopwatch, in words — `1:05`
    /// aloud is a time of day. While it runs the live text itself is the
    /// value, because a string computed here would be stale by the next
    /// second and this view deliberately never redraws to refresh it.
    static func accessibilityValue(_ stopwatch: Stopwatch, at now: Date) -> String {
        let words = StopwatchDisplay.spoken(elapsed: stopwatch.elapsed(at: now))
        return stopwatch.isReset ? words : String(localized: "Paused, \(words)", bundle: .creativeNotch)
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                digits
                    .notchFont(44, weight: .medium, design: .rounded)
                    .monospacedDigit()
                    .foregroundStyle(.ink(Self.digitsOpacity(isPaused: !stopwatch.isRunning && !stopwatch.isReset)))
                if let caption = Self.caption(stopwatch) {
                    Text(caption)
                        .notchFont(16, weight: .medium, design: .rounded)
                        .foregroundStyle(.ink(TimerTabView.captionOpacity(isPaused: true)))
                }
            }
            .modifier(StopwatchAccessibility(stopwatch: stopwatch, now: now, live: liveRange))

            laps

            HStack(spacing: 8) {
                if stopwatch.isRunning {
                    Button(String(localized: "Lap", bundle: .creativeNotch)) { onCommand(.lap) }.buttonStyle(NotchButtonStyle(.quiet))
                    Button(String(localized: "Pause", bundle: .creativeNotch)) { onCommand(.pause) }.buttonStyle(NotchButtonStyle(.quiet))
                } else if stopwatch.isReset {
                    Button(String(localized: "Start", bundle: .creativeNotch)) { onCommand(.start) }.buttonStyle(NotchButtonStyle(.prominent))
                } else {
                    Button(String(localized: "Reset", bundle: .creativeNotch)) { onCommand(.reset) }.buttonStyle(NotchButtonStyle(.quiet))
                    Button(String(localized: "Resume", bundle: .creativeNotch)) { onCommand(.start) }.buttonStyle(NotchButtonStyle(.prominent))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The span a live count runs over, or `nil` when the digits are static.
    /// Open-ended in practice: a hundred hours past the anchor.
    private var liveRange: ClosedRange<Date>? {
        guard countsLive, let anchor = stopwatch.anchor else { return nil }
        return anchor...anchor.addingTimeInterval(100 * 3600)
    }

    private var digits: Text {
        if let liveRange {
            return Text(timerInterval: liveRange, countsDown: false, showsHours: true)
        }
        return Text(StopwatchDisplay.text(elapsed: stopwatch.elapsed(at: now)))
    }

    /// The newest laps on one line, newest first. One line rather than a
    /// list so the pane fits at every text size; the latest few are the
    /// ones being compared. Always laid out, empty or not, so taking the
    /// first lap does not shift the digits.
    private var laps: some View {
        let recent = StopwatchDisplay.recentLaps(stopwatch.laps, limit: Self.visibleLaps)
        return HStack(spacing: 14) {
            ForEach(recent, id: \.number) { lap in
                HStack(spacing: 5) {
                    Text("Lap \(lap.number)", bundle: .creativeNotch)
                        .foregroundStyle(.ink(0.45))
                    Text(lap.text)
                        .monospacedDigit()
                        .foregroundStyle(.ink(0.8))
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(String(localized: "Lap \(lap.number)", bundle: .creativeNotch))
                .accessibilityValue(StopwatchDisplay.spoken(elapsed: stopwatch.laps[lap.number - 1]))
            }
        }
        .notchFont(12, weight: .medium, design: .rounded)
        .notchFrame(height: 16)
        .opacity(recent.isEmpty ? 0 : 1)
        .accessibilityHidden(recent.isEmpty)
    }
}

/// One element, "Stopwatch". Stopped, its value is the time in words;
/// running, the label carries the live count itself, so what VoiceOver
/// reads is the current second without this view redrawing to say it.
private struct StopwatchAccessibility: ViewModifier {
    let stopwatch: Stopwatch
    let now: Date
    let live: ClosedRange<Date>?

    func body(content: Content) -> some View {
        if let live {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    Text("Stopwatch, \(Text(timerInterval: live, countsDown: false, showsHours: true))", bundle: .creativeNotch)
                )
        } else {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(String(localized: "Stopwatch", bundle: .creativeNotch))
                .accessibilityValue(StopwatchView.accessibilityValue(stopwatch, at: now))
        }
    }
}

extension EnvironmentValues {
    /// Whether a running stopwatch's digits count live. On everywhere in the
    /// app, Reduce Motion included — a number changing is the information,
    /// not decoration, and it moves nothing. Off only where a render must be
    /// repeatable.
    @Entry var stopwatchCountsLive: Bool = true
}
