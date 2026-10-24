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

    /// Five seconds: long enough to read a file name and reach for it — the
    /// peek is the way to its file in Finder — and short enough that a
    /// download nobody was waiting for is gone before it is in the way.
    public static let downloadDoneTTL: TimeInterval = 5.0

    private var power: PowerEvent?
    private var powerExpiry: TimeInterval = 0
    private var dragActive = false
    private var nowPlaying: TrackSnapshot?
    private var timerDone: TimerCompletion?
    private var timerDoneExpiry: TimeInterval = 0
    private var downloads: DownloadSummary?
    private var downloadDone: DownloadCompletion?
    private var downloadDoneExpiry: TimeInterval = 0

    public init() {}

    /// What is downloading, or `nil`. Ambient, like now-playing: shown on
    /// hover, never unasked.
    public mutating func setDownloads(_ summary: DownloadSummary?) {
        downloads = summary
    }

    /// Below power and a finished timer, above everything ambient: a
    /// finished download is worth a glance, but it is neither consequential
    /// nor something the user asked to be interrupted by.
    public mutating func recordDownloadDone(_ completion: DownloadCompletion, now: TimeInterval) {
        downloadDone = completion
        downloadDoneExpiry = now + Self.downloadDoneTTL
    }

    /// Acknowledges the completion peek — it was clicked, or the panel opened
    /// — so the next hover does not show it again.
    public mutating func dismissDownloadDone() {
        downloadDone = nil
    }

    /// Withdraws both of the downloads module's entries when it is switched
    /// off, and nothing else's: the arbiter is a priority list, and whatever
    /// was queued behind them is revealed (`clearPower`'s reasoning).
    public mutating func clearDownloads() {
        downloads = nil
        downloadDone = nil
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
        if let downloadDone, now < downloadDoneExpiry { return .downloadDone(downloadDone) }
        // Above now-playing in the same order the badge slot uses, so a
        // hover over the download ring shows the download, not the track the
        // ring took the slot from.
        if let downloads { return .downloads(downloads) }
        if let nowPlaying, nowPlaying.isPlaying { return .nowPlaying(nowPlaying) }
        return nil
    }

    /// What a peek that is *already on screen* should become, when
    /// something changes underneath it.
    ///
    /// `content(now:)` answers "what would a hover show"; this answers a
    /// different question, and the two differ in exactly two places, both
    /// about the ambient now-playing peek:
    ///
    /// - **It is held while paused under the pointer.** Pressing Pause in
    ///   the peek is the peek's own control, and `content(now:)` drops a
    ///   paused track — so the peek collapsed under the click and Play was
    ///   never reachable from it. While the pointer is still over a
    ///   now-playing peek it stays, showing the paused track.
    /// - **It is never fallen back to without the pointer.** Ambient content
    ///   is something a hover asks for. Revealed underneath an expiring power
    ///   or timer peek with nobody hovering, it sat open indefinitely with
    ///   its equalizer running and its rect swallowing clicks; the badge on
    ///   the closed notch already says what is playing.
    ///
    /// Transient content is unaffected by either rule: it was not asked for
    /// and it expires on its own.
    public func content(
        now: TimeInterval,
        replacing showing: PeekContent,
        pointerInside: Bool
    ) -> PeekContent? {
        switch content(now: now) {
        case .nowPlaying(let track):
            return pointerInside ? .nowPlaying(track) : nil
        // Ambient for the same reason: kept, following the percent, while
        // the pointer is over it; never fallen back to without it.
        case .downloads(let summary):
            return pointerInside ? .downloads(summary) : nil
        case .some(let next):
            return next
        case nil:
            guard pointerInside, case .nowPlaying = showing, let nowPlaying else { return nil }
            return .nowPlaying(nowPlaying)
        }
    }
}
