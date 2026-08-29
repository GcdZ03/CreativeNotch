import Foundation

/// How often the clipboard is read, and why that is defensible.
///
/// `NSPasteboard` has no change notification, so this module is the
/// project's one admitted poller (spec section 5.3). Everything that makes
/// that acceptable is here, as pure arithmetic over two inputs: a fast
/// rate while things are happening, a back-off when they are not, and a
/// floor when the machine is trying to save power.
///
/// There is no state. "Resets on any change" is expressed by the caller
/// passing a smaller `sinceLastChange`, which keeps the whole policy
/// testable without a clock.
public enum ClipboardPollSchedule {

    /// While something is happening.
    public static let activeInterval: TimeInterval = 0.75

    /// After a quiet spell.
    public static let idleInterval: TimeInterval = 3.0

    /// How long a quiet spell has to be. Deliberately not user-idle:
    /// detecting that means polling `CGEventSource`, which would violate
    /// the rule this back-off exists to serve. Time since the last
    /// *clipboard* change is a proxy this module already has for free.
    public static let idleAfter: TimeInterval = 120

    /// The slowest this is allowed to go under Low Power Mode.
    public static let lowPowerFloor: TimeInterval = 2.0

    /// Low Power raises the floor rather than setting the interval, so the
    /// already-slower idle rate is left alone instead of being pulled
    /// *down* to 2s — which is what a plain assignment would do.
    ///
    /// A negative `sinceLastChange` is nonsense rather than an eternity:
    /// clocks are not guaranteed monotonic across sources, and the failure
    /// mode of reading it as "very idle" is a poller that backs off and
    /// never recovers.
    public static func interval(sinceLastChange: TimeInterval, lowPower: Bool) -> TimeInterval {
        let base = sinceLastChange >= idleAfter ? idleInterval : activeInterval
        return lowPower ? max(base, lowPowerFloor) : base
    }
}
