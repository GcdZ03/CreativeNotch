import Foundation

/// Decides what occupies the peek slot.
///
/// Transient sources preempt ambient ones, then fall back — the same model
/// as the iPhone Dynamic Island. Priority is drag, then a finished timer,
/// then HUD, then power, then media.
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

    /// Ten minutes, and an outlier among these TTLs for a reason: the
    /// others expire so the slot returns to ambient content, while this one
    /// exists only so an *unacknowledged* completion cannot hold the slot
    /// forever. A timer nobody came back to would otherwise block the HUD,
    /// power and now-playing peeks queued behind it, and volume feedback
    /// would silently stop working until someone clicked.
    public static let timerDoneTTL: TimeInterval = 600

    private var hud: HUDEvent?
    private var hudExpiry: TimeInterval = 0
    private var power: PowerEvent?
    private var powerExpiry: TimeInterval = 0
    private var dragActive = false
    private var nowPlaying: TrackSnapshot?
    private var timerDone: TimerCompletion?
    private var timerDoneExpiry: TimeInterval = 0

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
