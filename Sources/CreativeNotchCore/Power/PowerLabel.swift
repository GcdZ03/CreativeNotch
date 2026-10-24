import Foundation

/// Every string this module shows — which, since the time-remaining row
/// was removed, is one function.
///
/// Shared by the panel and the peek so the two cannot drift apart — the
/// pattern `NowPlayingLabel` established for the media module. It lives in
/// Core rather than beside the views because it is pure and worth testing,
/// which is exactly the case `CONTRIBUTING.md` says belongs down here:
/// the wording is then pinned with a plain `#expect` instead of through a
/// render.
public enum PowerLabel {

    /// What the machine is actually doing, in macOS's own vocabulary.
    ///
    /// "Plugged in" was the first attempt and it was the wrong thing to
    /// say. A machine on the adapter and not charging — which happens for
    /// real, and was measured on this machine at 52% with the battery
    /// actually draining — reported "Plugged in", which tells the user
    /// the cable is connected (something they can see) and hides the only
    /// interesting part. macOS calls this "Not charging"; so does this.
    ///
    /// `isCharged` is what keeps that from being alarming on a machine
    /// that has simply finished: full and idle is "Fully charged", not
    /// "Not charging".
    public static func state(
        source: PowerSource,
        isCharging: Bool,
        isCharged: Bool
    ) -> String {
        guard source == .wall else { return String(localized: "On battery", bundle: .creativeNotch) }
        if isCharging { return String(localized: "Charging", bundle: .creativeNotch) }
        return isCharged
            ? String(localized: "Fully charged", bundle: .creativeNotch)
            : String(localized: "Not charging", bundle: .creativeNotch)
    }

    /// The battery peek's words (2026-10-17), naming the event that fired.
    ///
    /// "Plugged In" rather than "Charging": the event says power arrived,
    /// and a Mac holding at 80% for battery health is plugged in without
    /// charging. `state(...)` above, which reads the live source, is where
    /// charging is named.
    public static func peekTitle(for event: PowerEvent) -> String {
        switch event {
        case .pluggedIn:  return String(localized: "Plugged In", bundle: .creativeNotch)
        case .unplugged:  return String(localized: "On Battery", bundle: .creativeNotch)
        case .lowBattery: return String(localized: "Low Battery", bundle: .creativeNotch)
        case .lowPowerMode(let enabled):
            return enabled
                ? String(localized: "Low Power Mode On", bundle: .creativeNotch)
                : String(localized: "Low Power Mode Off", bundle: .creativeNotch)
        }
    }

    /// The peek as one sentence, for VoiceOver: the title and, when the
    /// event carries one, the level — the same two things the row shows, in
    /// the same order. The bar is not spoken separately; it is the
    /// percentage drawn.
    ///
    /// Low Power Mode carries no level and must not invent one, which is
    /// the same rule `PowerPeekView.percentage` follows.
    public static func spoken(for event: PowerEvent) -> String {
        let title = peekTitle(for: event)
        switch event {
        case .pluggedIn(let level), .unplugged(let level), .lowBattery(_, let level):
            return String(localized: "\(title), \(level)%", bundle: .creativeNotch, comment: "Battery peek, spoken: the title, then the level")
        case .lowPowerMode:
            return title
        }
    }
}
