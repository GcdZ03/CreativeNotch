import Foundation

/// Decides what occupies the peek slot.
///
/// Transient sources preempt ambient ones, then fall back — the same model
/// as the iPhone Dynamic Island. Priority is drag, then HUD, then power,
/// then media.
///
/// `content(now:)` takes the time as a parameter rather than reading a
/// clock so TTL expiry is testable without sleeping.
public struct PeekArbiter: Equatable, Sendable {

    public static let hudTTL: TimeInterval = 1.5

    /// A power peek lives twice as long as a HUD one.
    ///
    /// A HUD peek confirms something the user did a moment ago and only
    /// has to be caught in passing. A power peek tells them something
    /// they did not know — the charger slipped out, the machine dropped
    /// into Low Power Mode — and needs long enough to be read rather than
    /// glimpsed.
    public static let powerTTL: TimeInterval = 3.0

    private var hud: HUDEvent?
    private var hudExpiry: TimeInterval = 0
    private var power: PowerEvent?
    private var powerExpiry: TimeInterval = 0
    private var dragActive = false
    private var nowPlaying: TrackSnapshot?

    public init() {}

    public mutating func recordHUD(_ event: HUDEvent, now: TimeInterval) {
        hud = event
        hudExpiry = now + Self.hudTTL
    }

    public mutating func recordPower(_ event: PowerEvent, now: TimeInterval) {
        power = event
        powerExpiry = now + Self.powerTTL
    }

    public mutating func setDragActive(_ active: Bool) {
        dragActive = active
    }

    public mutating func setNowPlaying(_ track: TrackSnapshot?) {
        nowPlaying = track
    }

    public func content(now: TimeInterval) -> PeekContent? {
        if dragActive { return .dragTarget }
        if let hud, now < hudExpiry { return .hud(hud) }
        // Between the two deliberately. A HUD peek answers a key the user
        // pressed a fraction of a second ago, and preempting it makes
        // their own keypress feel dropped. Now-playing is ambient
        // wallpaper and yields to anything. Power is unsolicited but
        // consequential, which is exactly the middle.
        if let power, now < powerExpiry { return .power(power) }
        if let nowPlaying, nowPlaying.isPlaying { return .nowPlaying(nowPlaying) }
        return nil
    }
}
