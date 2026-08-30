import Foundation

/// Every string this module shows.
///
/// Shared by the panel and the peek so the two cannot drift apart — the
/// pattern `NowPlayingLabel` established for the media module. It lives in
/// Core rather than beside the views because it is pure and worth testing,
/// which is exactly the case `CONTRIBUTING.md` says belongs down here:
/// the wording is then pinned with a plain `#expect` instead of through a
/// render.
public enum PowerLabel {

    /// Minutes as a duration, or the honest admission that there isn't one
    /// to give.
    ///
    /// `nil` is the ordinary case rather than an error: it is what
    /// `BatteryEstimateGate` returns for the whole settling window and any
    /// time consecutive readings disagree. The row keeps its place — a
    /// panel that changes height whenever the charger moves is worse than
    /// the noisy number the gate exists to suppress — and it never shows a
    /// stale value dressed as a current one.
    public static func timeRemaining(_ minutes: Int?) -> String {
        guard let minutes else { return "Estimating…" }
        // Under an hour reads as minutes. "0:45" looks like a clock that
        // has stopped rather than three quarters of an hour.
        guard minutes >= 60 else { return "\(minutes) min" }
        return "\(minutes / 60):\(String(format: "%02d", minutes % 60))"
    }

    /// What the machine is actually doing.
    ///
    /// Three states, not two. A machine at 100% on wall power is plugged in
    /// and not charging, and calling that "On battery" is simply false — it
    /// is also the exact state somebody opens the panel to confirm.
    public static func state(source: PowerSource, isCharging: Bool) -> String {
        switch (source, isCharging) {
        case (.wall, true):   return "Charging"
        case (.wall, false):  return "Plugged in"
        case (.battery, _):   return "On battery"
        }
    }

    /// The value for the time-remaining row, which depends on whether
    /// there is anything to estimate at all.
    ///
    /// Plugged in and not charging is neither a duration nor a pending
    /// one: nothing is filling, so no amount of waiting will produce a
    /// number. Saying "Estimating…" there is the same dishonesty as
    /// showing a stale value — it promises an answer that is not coming.
    ///
    /// This case is not hypothetical. IOKit reports `Time to Full Charge`
    /// as `0` when nothing is charging, which is "not applicable" rather
    /// than "zero minutes"; the observer now declines to read it, and this
    /// is what the panel says instead.
    public static func timeRemainingValue(
        minutes: Int?,
        source: PowerSource,
        isCharging: Bool
    ) -> String {
        if source == .wall && !isCharging { return "Not charging" }
        return timeRemaining(minutes)
    }

    /// The label for a time-remaining row, which is a different question
    /// depending on which way the charge is going.
    public static func timeRemainingTitle(source: PowerSource) -> String {
        source == .wall ? "Until full" : "Time remaining"
    }
}
