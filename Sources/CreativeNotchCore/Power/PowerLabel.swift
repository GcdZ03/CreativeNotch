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
        guard source == .wall else { return "On battery" }
        if isCharging { return "Charging" }
        return isCharged ? "Fully charged" : "Not charging"
    }
}
