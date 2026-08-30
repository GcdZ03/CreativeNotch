import SwiftUI
import CreativeNotchCore

/// Idle: presets and a custom field. Running: the remaining time and
/// pause / resume / cancel.
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

    @State private var customMinutes: String = ""

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
            HStack(spacing: 6) {
                TextField("minutes", text: $customMinutes)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                Button("Start") { startCustom() }
                    .disabled(parsedCustom == nil)
            }
        }
    }

    /// Parsed once and reused, so the button's enabled state and the action
    /// cannot disagree about whether the input is valid.
    private var parsedCustom: TimeInterval? {
        guard let minutes = Int(customMinutes.trimmingCharacters(in: .whitespaces)),
              minutes > 0,
              TimeInterval(minutes) * 60 <= Countdown.maxDuration
        else { return nil }
        return TimeInterval(minutes) * 60
    }

    private func startCustom() {
        guard let duration = parsedCustom else { return }
        onStart(duration)
        customMinutes = ""
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
