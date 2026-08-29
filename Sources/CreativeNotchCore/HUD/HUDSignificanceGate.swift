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

    /// The smallest single step that can have come from a person.
    ///
    /// `threshold` alone is not enough, because it compares against the
    /// last value *shown* and so lets tiny changes accumulate — which is
    /// deliberate for a slow slider drag, and catastrophic for the ambient
    /// light sensor, which ramps continuously and therefore accumulates
    /// past the threshold on its own. Measured on an M-series MacBook with
    /// nothing touched: 2301 events, 8 spurious HUDs.
    ///
    /// A rate gate cannot tell the two apart — an ambient ramp moves 0.046
    /// in a second, as fast as a drag. Per-*event* step size can:
    ///
    ///   ambient, 2063 samples: median 0.00012 · p99.9 0.00193 · worst 0.00326
    ///   a keypress or Control Center click: 0.0625 — 19x the worst ambient
    ///
    /// 0.005 leaves roughly 1.5x headroom over the worst ambient step
    /// measured. The cost is a full-range drag slower than about three
    /// seconds, whose steps fall under the floor and stop registering.
    public static let noiseFloor: Double = 0.005

    private enum Channel: Hashable {
        case volume
        case brightness
    }

    private var lastShown: [Channel: Double] = [:]

    /// Every level seen, shown or not — the baseline the noise floor
    /// measures each new event against. Distinct from `lastShown`, which
    /// deliberately lags so that small deliberate steps can accumulate.
    private var lastObserved: [Channel: Double] = [:]

    public init() {}

    /// Returns whether `kind` differs enough from what was last actually
    /// *shown* for its channel to be worth showing again.
    ///
    /// A pure query: it does not update the baseline. Significance and
    /// display are decided at different points -- attribution can still
    /// suppress a change this reports as significant -- so committing here
    /// would advance the baseline for a value the caller never displays.
    /// Call `commitShown` separately, and only once the caller has
    /// actually displayed `kind`.
    public func isSignificant(_ kind: HUDKind) -> Bool {
        switch kind {
        case .mute:
            return true
        case .volume(let level):
            return isSignificantLevel(.volume, level)
        case .brightness(let level):
            return isSignificantLevel(.brightness, level)
        }
    }

    private func isSignificantLevel(_ channel: Channel, _ level: Double) -> Bool {
        guard let last = lastShown[channel] else { return true }
        return abs(level - last) >= Self.threshold
    }

    /// Whether this event moved far enough in one step to have come from
    /// a person rather than from the ambient light sensor.
    ///
    /// A pure query, like `isSignificant`: call `commitObserved` for
    /// *every* event regardless of the answer. Skipping the commit for
    /// filtered events would let ambient drift accumulate against a stale
    /// baseline and eventually cross the floor anyway — reintroducing
    /// exactly the bug this closes.
    public func isAboveNoiseFloor(_ kind: HUDKind) -> Bool {
        switch kind {
        case .mute:
            // No magnitude, so no noise floor applies.
            return true
        case .volume(let level):
            return isAboveFloor(.volume, level)
        case .brightness(let level):
            return isAboveFloor(.brightness, level)
        }
    }

    private func isAboveFloor(_ channel: Channel, _ level: Double) -> Bool {
        // Nothing seen yet: the first change after launch must not be
        // silently swallowed for want of a baseline.
        guard let last = lastObserved[channel] else { return true }
        return abs(level - last) >= Self.noiseFloor
    }

    /// Records `kind` as the most recent level seen for its channel,
    /// whether or not it passed any filter. Call for every event.
    public mutating func commitObserved(_ kind: HUDKind) {
        switch kind {
        case .mute:
            break
        case .volume(let level):
            lastObserved[.volume] = level
        case .brightness(let level):
            lastObserved[.brightness] = level
        }
    }

    /// Records `kind` as the value actually shown for its channel, so
    /// future comparisons are against what is really on screen.
    ///
    /// Call this only when `kind` was actually displayed -- never merely
    /// because `isSignificant` returned `true`, since a later filter (a
    /// keypress attribution, for instance) may still keep it off screen.
    public mutating func commitShown(_ kind: HUDKind) {
        switch kind {
        case .mute:
            break
        case .volume(let level):
            lastShown[.volume] = level
        case .brightness(let level):
            lastShown[.brightness] = level
        }
    }
}
