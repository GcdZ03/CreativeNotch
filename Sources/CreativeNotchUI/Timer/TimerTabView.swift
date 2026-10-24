import SwiftUI
import CreativeNotchCore

/// Idle: presets and a click-only stepper. Running: the remaining time and
/// pause / resume / cancel.
///
/// Two ways to reach the same number, sharing one value: the stepper for a
/// couple of clicks, the field for an exact figure.
///
/// The field is the only control in the project that types, and it is why
/// `NotchPanel.canBecomeKey` is `true` and `AppDelegate.syncKeyWindow` makes
/// the panel key on this tab however it was opened — even by hover, which
/// otherwise never takes the keyboard (`PanelFocus`). An earlier version
/// shipped a field while the panel could never become key: it rendered, and
/// swallowed every keystroke.
///
/// The stepper stays, and is not a fallback. It is the faster path for the
/// common case, and it is the only one that works if focus is ever refused.
///
/// The presets are **replaced**, not merely disabled, while a timer runs.
/// A second countdown (2026-10-24) is asked for deliberately, through the
/// title row's Add, which brings this same picker back (`isAdding`) — so
/// one running timer looks exactly as it did when one was the whole model,
/// and nobody starts a second by brushing a preset.
///
/// Two or more running are a list (`list`): one row each, with its own
/// pause and cancel, in start order (`TimerSet`).
///
/// Presentation only: every control calls a closure. Nothing here starts,
/// schedules, or owns a timer — `TimerController` is what turns `onStart`
/// into a real countdown, and `AppState.timers` is what this view renders
/// from once one exists.
struct TimerTabView: View {
    let timers: [RunningTimer]
    let now: Date
    /// Three, in minutes, each already within `Limits.presetRange` — chosen
    /// in Settings (2026-10-24), 5 / 10 / 25 until then.
    var presets: [Int] = Limits.defaultTimerPresets
    /// Showing the picker for one more countdown beside those running.
    var isAdding = false
    var onStart: (TimeInterval) -> Void
    var onPause: (Int) -> Void
    var onResume: (Int) -> Void
    var onCancel: (Int) -> Void

    @State private var customMinutes: Int = 15
    /// For the track's width, which grows with the digits above it.
    @Environment(\.notchTextScale) private var textScale
    /// Only an offscreen render sets this: `ImageRenderer` cannot host the
    /// AppKit view behind a `TextField` and draws a placeholder in its place.
    @Environment(\.notchDrawsFieldsAsText) private var fieldsAsText

    /// Which of the three layouts to draw. Static so the choice is pinned
    /// by a test without rendering.
    enum Layout: Equatable { case picker, single, list }

    static func layout(count: Int, isAdding: Bool) -> Layout {
        if count == 0 || isAdding { return .picker }
        return count == 1 ? .single : .list
    }

    var body: some View {
        switch Self.layout(count: timers.count, isAdding: isAdding) {
        case .picker: idle
        case .single: running(timers[0])
        case .list: list
        }
    }

    /// The track's fill, from Core. Static so the argument order is pinned
    /// by a test without rendering.
    static func trackFraction(_ countdown: Countdown, at now: Date) -> Double {
        TimerProgress.fraction(countdown, at: now)
    }

    /// The digits dim while paused. Unchanged from when dimming was the
    /// whole signal.
    static func digitsOpacity(isPaused: Bool) -> Double {
        isPaused ? 0.45 : 0.95
    }

    /// The caption is quieter than the digits while running (the 0.55 of
    /// the digits' white it always had, so the running look is unchanged)
    /// and *louder* than them while paused. It used to inherit the digits'
    /// dimming, which would have drawn "paused" at a quarter white — the
    /// one word that says what dimming cannot, made the hardest to read.
    static func captionOpacity(isPaused: Bool) -> Double {
        isPaused ? 0.75 : digitsOpacity(isPaused: false) * 0.55
    }

    /// What VoiceOver reads for the countdown: the time left in words and
    /// the bar as a percentage, from the same `now` both are drawn from.
    ///
    /// It changes only when the view redraws, which is when the digits
    /// change — once a minute above a minute — so VoiceOver is never handed
    /// a value more often than the screen is, and reads the current one
    /// whenever the cursor lands on it.
    static func accessibilityValue(_ countdown: Countdown, at now: Date) -> String {
        TimerSpokenText.value(
            remaining: countdown.remaining(at: now),
            isPaused: countdown.isPaused,
            fraction: trackFraction(countdown, at: now)
        )
    }

    private var idle: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                // By position, not by value: two presets set to the same
                // number are still two buttons.
                ForEach(Array(presets.enumerated()), id: \.offset) { _, minutes in
                    Button("\(minutes) min") { onStart(TimeInterval(minutes) * 60) }
                        .buttonStyle(NotchButtonStyle(.quiet))
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
                if fieldsAsText {
                    NotchFieldStyle.staticText("\(customMinutes)")
                        .notchFrame(width: 52)
                } else {
                    TextField("", value: $customMinutes, format: .number)
                        .textFieldStyle(NotchFieldStyle())
                        .notchFrame(width: 52)
                        .onSubmit { start() }
                        .onChange(of: customMinutes) { _, typed in
                            customMinutes = min(
                                TimerStepper.maximum,
                                max(TimerStepper.minimum, typed)
                            )
                        }
                        .accessibilityLabel("Minutes")
                }

                stepButton("plus", disabled: customMinutes == TimerStepper.maximum) {
                    customMinutes = TimerStepper.increment(customMinutes)
                }

                Button("Start", action: start)
                    .buttonStyle(NotchButtonStyle(.prominent))
                    .padding(.leading, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                .notchFont(11, weight: .bold)
                .notchFrame(width: 12, height: 12)
        }
        .buttonStyle(NotchButtonStyle(.quiet))
        .disabled(disabled)
        .accessibilityLabel(symbol == "plus" ? "Longer" : "Shorter")
    }

    private func running(_ timer: RunningTimer) -> some View {
        let countdown = timer.countdown
        return VStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                let remaining = TimerDisplay.text(remaining: countdown.remaining(at: now))
                Text(remaining)
                    .notchFont(44, weight: .medium, design: .rounded)
                    .monospacedDigit()
                    .rollingDigits(remaining, countsDown: true)
                    // Dimming says paused at a glance, as it does in the
                    // ear (where a pause glyph stands in for the word).
                    .foregroundStyle(.ink(Self.digitsOpacity(isPaused: countdown.isPaused)))
                // The word says it outright, for anyone two greys do not
                // separate — see `TimerDisplay.caption`.
                Text(TimerDisplay.caption(isPaused: countdown.isPaused))
                    .notchFont(16, weight: .medium, design: .rounded)
                    .foregroundStyle(.ink(Self.captionOpacity(isPaused: countdown.isPaused)))
            }
            // One element, "Timer", whose value is the digits, "left" and
            // the bar below said as a sentence — `25m` read aloud is "25 m",
            // and dimming is invisible to VoiceOver.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Timer")
            .accessibilityValue(Self.accessibilityValue(countdown, at: now))

            // Redraws exactly when the digits do: same `now`, no clock of
            // its own.
            track(countdown)
                .frame(width: NotchType.length(220, scale: textScale), height: 4)

            HStack(spacing: 8) {
                if countdown.isPaused {
                    Button("Resume") { onResume(timer.id) }.buttonStyle(NotchButtonStyle(.prominent))
                } else {
                    Button("Pause") { onPause(timer.id) }.buttonStyle(NotchButtonStyle(.quiet))
                }
                Button("Cancel") { onCancel(timer.id) }.buttonStyle(NotchButtonStyle(.quiet))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The progress track, from Core. Spoken as part of the countdown's
    /// value wherever it is drawn, so never a stop of its own.
    private func track(_ countdown: Countdown) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.hairline(0.14))
                Capsule()
                    .fill(.ink(countdown.isPaused ? 0.45 : 0.95))
                    .frame(width: geometry.size.width * Self.trackFraction(countdown, at: now))
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: - Several

    /// What a row's countdown is called aloud: by the duration it was set
    /// to, so three rows are three different names rather than "Timer"
    /// three times.
    static func rowName(_ countdown: Countdown) -> String {
        TimerSpokenText.name(duration: countdown.duration)
    }

    /// One row per countdown, in start order: what it was set to, what is
    /// left, its track, and its own pause and cancel. The same digits,
    /// caption, dimming and track as the single view, smaller — every row
    /// redraws on the controller's one shared wake, never on a clock of its
    /// own.
    private var list: some View {
        VStack(spacing: 10) {
            ForEach(timers) { timer in
                row(timer)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ timer: RunningTimer) -> some View {
        let countdown = timer.countdown
        let remaining = TimerDisplay.text(remaining: countdown.remaining(at: now))
        let name = Self.rowName(countdown)
        return HStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(NotchRootView.durationLabel(countdown))
                    .notchFont(11, weight: .medium, design: .rounded)
                    .foregroundStyle(.ink(0.45))
                    .notchFrame(width: 40, alignment: .leading)
                Text(remaining)
                    .notchFont(20, weight: .medium, design: .rounded)
                    .monospacedDigit()
                    .rollingDigits(remaining, countsDown: true)
                    .foregroundStyle(.ink(Self.digitsOpacity(isPaused: countdown.isPaused)))
                Text(TimerDisplay.caption(isPaused: countdown.isPaused))
                    .notchFont(11, weight: .medium, design: .rounded)
                    .foregroundStyle(.ink(Self.captionOpacity(isPaused: countdown.isPaused)))
            }
            .notchFrame(width: 140, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(name)
            .accessibilityValue(Self.accessibilityValue(countdown, at: now))

            track(countdown)
                .frame(height: 4)
                .frame(maxWidth: .infinity)

            rowButton(
                countdown.isPaused ? "play.fill" : "pause.fill",
                label: "\(countdown.isPaused ? "Resume" : "Pause") \(name)"
            ) {
                countdown.isPaused ? onResume(timer.id) : onPause(timer.id)
            }
            rowButton("xmark", label: "Cancel \(name)") { onCancel(timer.id) }
        }
    }

    /// A glyph in the panel's compact capsule, named for VoiceOver by the
    /// row it acts on.
    private func rowButton(
        _ symbol: String, label: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .notchFont(10, weight: .bold)
                .notchFrame(width: 12, height: 12)
        }
        .buttonStyle(NotchButtonStyle(.quiet, compact: true))
        .accessibilityLabel(label)
    }
}
