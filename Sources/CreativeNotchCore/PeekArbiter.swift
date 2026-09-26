import Foundation

/// Decides what occupies the peek slot.
///
/// Transient sources preempt ambient ones, then fall back — the same model
/// as the iPhone Dynamic Island. Priority is drag, then a finished timer,
/// then power, then media.
///
/// `content(now:)` takes the time as a parameter rather than reading a
/// clock so TTL expiry is testable without sleeping.
public struct PeekArbiter: Equatable, Sendable {

    /// A power peek tells the user something they did not know — the
    /// charger slipped out, the machine dropped into Low Power Mode — so it
    /// needs long enough to be read rather than glimpsed.
    public static let powerTTL: TimeInterval = 3.0

    /// Ten minutes, and an outlier among these TTLs for a reason: the
    /// others expire so the slot returns to ambient content, while this one
    /// exists only so an *unacknowledged* completion cannot hold the slot
    /// forever. A timer nobody came back to would otherwise block the power
    /// and now-playing peeks queued behind it, and they would silently stop
    /// appearing until someone clicked.
    public static let timerDoneTTL: TimeInterval = 600

    private var power: PowerEvent?
    private var powerExpiry: TimeInterval = 0
    private var dragActive = false
    private var nowPlaying: TrackSnapshot?
    private var timerDone: TimerCompletion?
    private var timerDoneExpiry: TimeInterval = 0

    public init() {}

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

    /// Above power: a finished timer is something the user explicitly asked
    /// to be interrupted by. Below drag: interrupting an in-flight drag
    /// would tear down a drop target mid-gesture.
    public mutating func recordTimerFinished(_ completion: TimerCompletion, now: TimeInterval) {
        timerDone = completion
        timerDoneExpiry = now + Self.timerDoneTTL
    }

    /// Acknowledges the completion peek, clearing it immediately rather
    /// than waiting out `timerDoneTTL`.
    public mutating func dismissTimerDone() {
        timerDone = nil
    }

    /// Withdraws a power peek whose module has just been switched off.
    ///
    /// The counterpart to `dismissTimerDone`, and needed for the same reason:
    /// toggles take effect immediately, so a peek already in the slot has to
    /// be withdrawn rather than waited out. A peek that outlives its module
    /// being disabled is small, visible, and exactly what makes a preference
    /// feel unreliable.
    ///
    /// It clears only its own module. Blanking the arbiter would pass the
    /// obvious test while silently cancelling another module's interruption,
    /// and would hide whatever was queued behind this one -- the arbiter is a
    /// priority list, so withdrawing the top entry reveals the next.
    public mutating func clearPower() {
        power = nil
    }

    public func content(now: TimeInterval) -> PeekContent? {
        if dragActive { return .dragTarget }
        if let timerDone, now < timerDoneExpiry { return .timerDone(timerDone) }
        // Above now-playing deliberately: now-playing is ambient wallpaper
        // and yields to anything, while power is unsolicited but
        // consequential.
        if let power, now < powerExpiry { return .power(power) }
        if let nowPlaying, nowPlaying.isPlaying { return .nowPlaying(nowPlaying) }
        return nil
    }
}
