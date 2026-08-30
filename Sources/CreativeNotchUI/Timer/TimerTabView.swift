import SwiftUI
import CreativeNotchCore

/// Idle: presets and a click-only stepper. Running: the remaining time and
/// pause / resume / cancel.
///
/// Two ways to reach the same number, sharing one value: the stepper for a
/// couple of clicks, the field for an exact figure.
///
/// The field is the only control in the project that needs the keyboard, and
/// it is the reason `NotchPanel.canBecomeKey` is `true` and
/// `AppDelegate.syncKeyWindow` makes the panel key on this tab alone. An
/// earlier version shipped a field while the panel could never become key:
/// it rendered, and swallowed every keystroke.
///
/// The stepper stays, and is not a fallback. It is the faster path for the
/// common case, and it is the only one that works if focus is ever refused.
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
            HStack(spacing: 8) {
                stepButton("minus", disabled: customMinutes == TimerStepper.minimum) {
                    customMinutes = TimerStepper.decrement(customMinutes)
                }

                // Bound to the same `customMinutes` the stepper edits, so
                // there is one value rather than two views arguing about it:
                // stepping updates the field, typing moves what the steppers
                // step from.
                //
                // The clamp is what stops a typed 500 reaching `Countdown`,
                // which would reject it and leave Start silently doing
                // nothing — a dead button being the worst of the options.
                TextField("", value: $customMinutes, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 54)
                    .multilineTextAlignment(.center)
                    .monospacedDigit()
                    .onSubmit { start() }
                    .onChange(of: customMinutes) { _, typed in
                        customMinutes = min(
                            TimerStepper.maximum,
                            max(TimerStepper.minimum, typed)
                        )
                    }
                    .accessibilityLabel("Minutes")

                stepButton("plus", disabled: customMinutes == TimerStepper.maximum) {
                    customMinutes = TimerStepper.increment(customMinutes)
                }

                Button("Start", action: start)
                    .buttonStyle(.bordered)
            }
        }
    }

    private func start() {
        onStart(TimeInterval(customMinutes) * 60)
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
