import Foundation

/// Drops the duplicate callbacks CoreAudio emits for a single change.
///
/// The feasibility spike measured **8 listener callbacks for 4 volume
/// changes** — pairs about a millisecond apart carrying identical values.
/// Letting both through flickers the pill and restarts the peek TTL twice.
///
/// Only an *exact repeat* within `minimumInterval` is dropped. Dragging a
/// slider produces a genuine stream of distinct values, and those must all
/// pass or the level would appear to lag behind the cursor.
public struct HUDCoalescer: Equatable, Sendable {

    /// Duplicates arrive about a millisecond apart; a twentieth of a second
    /// is comfortably wider than that and far below what a human notices.
    public static let minimumInterval: TimeInterval = 0.05

    private var last: (kind: HUDKind, at: TimeInterval)?

    public init() {}

    /// Returns whether this event should be shown.
    public mutating func accept(_ kind: HUDKind, at time: TimeInterval) -> Bool {
        if let last, last.kind == kind, time - last.at <= Self.minimumInterval {
            return false
        }
        last = (kind, time)
        return true
    }

    public static func == (lhs: HUDCoalescer, rhs: HUDCoalescer) -> Bool {
        lhs.last?.kind == rhs.last?.kind && lhs.last?.at == rhs.last?.at
    }
}
