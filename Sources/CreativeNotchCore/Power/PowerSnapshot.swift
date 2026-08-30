import Foundation

/// Where the machine is drawing power from.
///
/// Two cases, not three: IOKit also reports a UPS type, which this app
/// does not read. An external UPS is not what the notch is for, and
/// pretending to support one by mapping it onto `.wall` would report a
/// desktop as plugged in while its battery backup discharges.
public enum PowerSource: String, Equatable, Sendable {
    case battery, wall
}

/// The machine's power state at one instant, as a plain value.
///
/// This is the boundary. Above it, every decision in this module is pure
/// logic over this struct and runs headlessly — including on CI machines
/// and desktops with no battery at all. Below it, `PowerObserver` is the
/// only thing that touches IOKit.
///
/// `level` is whole percent because that is what IOKit reports and what
/// the panel shows; converting to a fraction and back would invent
/// precision that never existed, and both low-battery thresholds are
/// stated in whole percent.
///
/// There is deliberately no time-remaining estimate here. It was built,
/// shipped, and removed: see "Deliberately not built" in
/// `docs/plans/2026-08-30-battery.md`. Its absence is what lets
/// `PowerObserver.read()` drop most of IOKit's notifications, because the
/// estimate was the field that changed on nearly every one of them.
public struct PowerSnapshot: Equatable, Sendable {

    public var level: Int
    public var source: PowerSource
    public var isCharging: Bool

    /// Whether the battery is full and has stopped taking charge.
    ///
    /// Distinct from `!isCharging`, and the distinction is the difference
    /// between "finished" and "something is wrong". A machine plugged in
    /// at 52% that is not charging — measured on a real machine, adapter
    /// attached, battery actually draining — is not the same state as one
    /// sitting at 100%, and calling both "Not charging" alarms in one case
    /// and confuses in the other.
    public var isCharged: Bool


    public var isLowPowerMode: Bool

    public init(
        level: Int,
        source: PowerSource,
        isCharging: Bool,
        isCharged: Bool = false,
        isLowPowerMode: Bool
    ) {
        self.level = level
        self.source = source
        self.isCharging = isCharging
        self.isCharged = isCharged
        self.isLowPowerMode = isLowPowerMode
    }

    /// Whether the charger is attached.
    ///
    /// Derived from the source, never from `isCharging`: a machine sitting
    /// at 100% on wall power is plugged in and not charging, and deriving
    /// one from the other shows "on battery" with the cable in your hand.
    public var isPluggedIn: Bool { source == .wall }
}
