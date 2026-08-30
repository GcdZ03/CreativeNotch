import SwiftUI
import CreativeNotchCore

/// Idle: presets and a click-only stepper. Running: the remaining time and
/// pause / resume / cancel.
///
/// The stepper is not a stylistic choice. `NotchPanel` overrides
/// `canBecomeKey` to `false` so opening the notch never steals focus from
/// whatever you are working in — and a window that cannot become key cannot
/// give keyboard focus to a `TextField`. An earlier version of this view had
/// one; it rendered, and swallowed every keystroke. Every control here must
/// be reachable by mouse alone.
///
/// The presets are **replaced**, not merely disabled, while a timer runs.
/// One timer at a time is the model, and a visible preset button would
/// promise a second one the model cannot deliver.
///
/// Presentation only: every control calls a closure. Nothing here starts,
/// schedules, or owns a timer — `TimerController` (a later module) is what
/// turns `onStart` into a real countdown, and `AppState.countdown` is what
/// this view renders `running` from once one exists.
struct TimerTabView: View {
    let countdown: Countdown?
    let now: Date
    var onStart: (TimeInterval) -> Void
    var onPause: () -> Void
    var onResume: () -> Void
    var onCancel: () -> Void

    /// 5 / 10 / 25. The last is a pomodoro; the first two cover the
    /// kitchen-timer cases without opening the custom field.
    private static let presets: [Int] = [5, 10, 25]

    @State private var customMinutes: Int = 15

    var body: some View {
        if let countdown {
            running(countdown)
        } else {
            idle
        }
    }

    private var idle: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                ForEach(Self.presets, id: \.self) { minutes in
                    Button("\(minutes)m") { onStart(TimeInterval(minutes) * 60) }
                        .buttonStyle(.borderedProminent)
                }
            }
            HStack(spacing: 12) {
                stepButton("minus", disabled: customMinutes == TimerStepper.minimum) {
                    customMinutes = TimerStepper.decrement(customMinutes)
                }

                // Monospaced digits and a fixed width, so the Start button
                // does not shuffle sideways as the number changes.
                Text("\(customMinutes)m")
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.95))
                    .frame(width: 46)
                    .accessibilityLabel("\(customMinutes) minutes")

                stepButton("plus", disabled: customMinutes == TimerStepper.maximum) {
                    customMinutes = TimerStepper.increment(customMinutes)
                }

                Button("Start") { onStart(TimeInterval(customMinutes) * 60) }
                    .buttonStyle(.bordered)
            }
        }
    }

    /// Disabled at the ends rather than silently clamping, so a button that
    /// will not move says so before it is clicked.
    private func stepButton(
        _ symbol: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.bordered)
        .disabled(disabled)
        .accessibilityLabel(symbol == "plus" ? "Longer" : "Shorter")
    }

    private func running(_ countdown: Countdown) -> some View {
        VStack(spacing: 12) {
            Text(TimerDisplay.text(remaining: countdown.remaining(at: now)))
                .font(.system(size: 34, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(countdown.isPaused ? 0.45 : 0.95))

            HStack(spacing: 10) {
                if countdown.isPaused {
                    Button("Resume", action: onResume).buttonStyle(.borderedProminent)
                } else {
                    Button("Pause", action: onPause).buttonStyle(.bordered)
                }
                Button("Cancel", action: onCancel).buttonStyle(.bordered)
            }
        }
    }
}
