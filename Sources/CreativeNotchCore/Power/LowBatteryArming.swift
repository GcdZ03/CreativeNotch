import Foundation

/// Decides when a low-battery level is worth interrupting for, and — more
/// importantly — when it is not any more.
///
/// The thresholds are the two macOS itself warns at. The hard part is not
/// crossing them but not re-crossing them: IOKit reports whole percent
/// over a continuous charge, so a battery near a threshold jitters back
/// and forth across it, and an ungated check would fire the same peek
/// indefinitely. That is the same failure `HUDSignificanceGate` exists to
/// prevent for the ambient light sensor.
///
/// So each threshold is *armed* or not. It fires once when crossed, and
/// re-arms only when the level rises back above it — charging to 21% arms
/// the 20% threshold; sitting at 20% does not.
public struct LowBatteryArming: Equatable, Sendable {

    /// Descending, and the order matters: `crossing` walks these to find
    /// the most urgent one crossed.
    public static let thresholds: [Int] = [20, 10]

    /// Which thresholds have not spoken yet. Everything starts armed: a
    /// machine that launches the app already at 8% has a problem worth
    /// mentioning.
    private var armed: Set<Int> = Set(thresholds)

    public init() {}

    /// Returns the threshold to announce, or `nil` for silence.
    ///
    /// - Parameter isPluggedIn: from `PowerSnapshot.isPluggedIn` — the
    ///   source, not `isCharging`. A machine at 100% on wall power is not
    ///   discharging even though it is not charging either.
    public mutating func crossing(level: Int, isPluggedIn: Bool) -> Int? {
        // Re-arm on the way up regardless of source. The level rising is
        // what resolves a warning; requiring the charger to still be
        // attached at the moment of the check would leave a threshold
        // disarmed after a top-up that ended a minute ago.
        for threshold in Self.thresholds where level > threshold {
            armed.insert(threshold)
        }

        // A machine on wall power has no problem to announce. Passing 20%
        // on the way up is good news, and good news does not interrupt.
        guard !isPluggedIn else { return nil }

        let crossed = Self.thresholds.filter { level <= $0 && armed.contains($0) }
        guard !crossed.isEmpty else { return nil }

        // All of them are spent, but only the most urgent speaks. A
        // machine that slept at 25% and woke at 8% crossed both; showing
        // the 20% warning and replacing it with the 10% one in the same
        // breath is worse than showing either alone.
        for threshold in crossed { armed.remove(threshold) }
        return crossed.min()
    }
}
