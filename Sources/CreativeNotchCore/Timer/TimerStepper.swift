import Foundation

/// Stepping a custom duration up and down, in whole minutes.
///
/// This exists as a pure function rather than as `@State` arithmetic inside
/// the view for the usual reason in this project — it is testable without
/// rendering anything — and for one specific to it: the panel is a
/// non-activating `NSPanel` that can never become the key window, so a
/// `TextField` here would render and then swallow every keystroke. The
/// stepper is the input method, not a convenience beside one, and its
/// behaviour is worth pinning.
public enum TimerStepper {

    /// One minute at a time below ten, five at a time from ten up.
    ///
    /// Fine control is only useful where the durations are short: the
    /// difference between 3 and 4 minutes matters, the difference between
    /// 40 and 41 does not. The threshold makes reaching 45 four clicks
    /// instead of thirty-five.
    static func stepSize(at minutes: Int, goingUp: Bool) -> Int {
        // Asymmetric around the threshold on purpose, so stepping is
        // reversible: 9 +1 lands on 10, and 10 -1 lands back on 9. A single
        // `>= 10` rule either strands 10 (up 5, down 5, never reaching 9) or
        // makes the pair non-invertible.
        goingUp ? (minutes >= 10 ? 5 : 1)
                : (minutes > 10 ? 5 : 1)
    }

    public static let minimum = 1

    /// 99, derived rather than spelled again — the cap is
    /// `Countdown.maxDuration`, and the display format is only sized for
    /// three glyphs because of it.
    public static var maximum: Int { Int(Countdown.maxDuration / 60) }

    /// The next value up, clamped. Already at the cap returns the cap.
    public static func increment(_ minutes: Int) -> Int {
        min(maximum, minutes + stepSize(at: minutes, goingUp: true))
    }

    /// The next value down, clamped. Already at the floor returns the floor.
    public static func decrement(_ minutes: Int) -> Int {
        max(minimum, minutes - stepSize(at: minutes, goingUp: false))
    }
}
