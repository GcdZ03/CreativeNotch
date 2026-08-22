import Foundation

/// Decides what occupies the peek slot.
///
/// Transient sources preempt ambient ones, then fall back — the same model
/// as the iPhone Dynamic Island. Priority is drag, then HUD, then media.
///
/// `content(now:)` takes the time as a parameter rather than reading a
/// clock so TTL expiry is testable without sleeping.
public struct PeekArbiter: Equatable, Sendable {

    public static let hudTTL: TimeInterval = 1.5

    private var hud: HUDEvent?
    private var hudExpiry: TimeInterval = 0
    private var dragActive = false
    private var nowPlaying: TrackSnapshot?

    public init() {}

    public mutating func recordHUD(_ event: HUDEvent, now: TimeInterval) {
        hud = event
        hudExpiry = now + Self.hudTTL
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
        if let nowPlaying, nowPlaying.isPlaying { return .nowPlaying(nowPlaying) }
        return nil
    }
}
