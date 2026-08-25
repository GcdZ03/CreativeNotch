import Foundation

/// Drops level changes too small for a human to have asked for.
///
/// The ambient light sensor micro-adjusts the backlight roughly 60 times a
/// second — 1729 events measured in one short session, every one a
/// distinct value, so `HUDCoalescer` (which only drops exact repeats)
/// cannot help. Left unfiltered, the notch would strobe continuously,
/// which is exactly what the project's no-polling rule exists to prevent.
///
/// A change is significant when it differs from the last level actually
/// *shown* for that kind by at least `threshold`. Comparing against the
/// last shown value rather than the last observed one is deliberate: a
/// slow Control Center slider drag then accumulates across many small,
/// individually-insignificant steps until it crosses the threshold and
/// shows, rather than being filtered away step by step forever.
///
/// `.mute` carries no magnitude, so the threshold comparison does not
/// apply to it — every mute event is significant.
public struct HUDSignificanceGate: Equatable, Sendable {

    /// The keys move volume and brightness in 1/16 (0.0625) steps;
    /// ambient drift is on the order of 0.00007. 1/32 sits comfortably
    /// between the two and is exactly representable in binary floating
    /// point, so boundary comparisons are exact.
    public static let threshold: Double = 0.03125

    private enum Channel: Hashable {
        case volume
        case brightness
    }

    private var lastShown: [Channel: Double] = [:]

    public init() {}

    /// Returns whether this event differs enough from what was last shown
    /// for its kind to be worth showing again.
    public mutating func accept(_ kind: HUDKind) -> Bool {
        switch kind {
        case .mute:
            return true
        case .volume(let level):
            return acceptLevel(.volume, level)
        case .brightness(let level):
            return acceptLevel(.brightness, level)
        }
    }

    private mutating func acceptLevel(_ channel: Channel, _ level: Double) -> Bool {
        guard let last = lastShown[channel] else {
            lastShown[channel] = level
            return true
        }
        guard abs(level - last) >= Self.threshold else { return false }
        lastShown[channel] = level
        return true
    }
}
