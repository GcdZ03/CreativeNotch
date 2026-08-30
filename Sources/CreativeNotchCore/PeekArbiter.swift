import Foundation

/// Decides what occupies the peek slot.
///
/// Transient sources preempt ambient ones, then fall back — the same model
/// as the iPhone Dynamic Island. Priority is drag, then a finished timer,
/// then HUD, then media.
///
/// `content(now:)` takes the time as a parameter rather than reading a
/// clock so TTL expiry is testable without sleeping.
public struct PeekArbiter: Equatable, Sendable {

    public static let hudTTL: TimeInterval = 1.5

    /// Ten minutes. Not about the timer: an unattended completion that
    /// never expired would hold the peek state indefinitely and block the
    /// HUD and now-playing peeks queued behind it, so volume feedback would
    /// silently stop working until someone came back and clicked.
    public static let timerDoneTTL: TimeInterval = 600

    private var hud: HUDEvent?
    private var hudExpiry: TimeInterval = 0
    private var dragActive = false
    private var nowPlaying: TrackSnapshot?
    private var timerDone: TimerCompletion?
    private var timerDoneExpiry: TimeInterval = 0

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

    /// Above the HUD: a finished timer is something the user explicitly
    /// asked to be interrupted by, and volume feedback is not. Below drag:
    /// interrupting an in-flight drag would tear down a drop target
    /// mid-gesture.
    public mutating func recordTimerFinished(_ completion: TimerCompletion, now: TimeInterval) {
        timerDone = completion
        timerDoneExpiry = now + Self.timerDoneTTL
    }

    /// Acknowledges the completion peek, clearing it immediately rather
    /// than waiting out `timerDoneTTL`.
    public mutating func dismissTimerDone() {
        timerDone = nil
    }

    public func content(now: TimeInterval) -> PeekContent? {
        if dragActive { return .dragTarget }
        if let timerDone, now < timerDoneExpiry { return .timerDone(timerDone) }
        if let hud, now < hudExpiry { return .hud(hud) }
        if let nowPlaying, nowPlaying.isPlaying { return .nowPlaying(nowPlaying) }
        return nil
    }
}
