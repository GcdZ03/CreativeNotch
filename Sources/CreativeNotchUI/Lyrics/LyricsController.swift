import Foundation
import CreativeNotchCore

/// How a lyrics request reaches the service: the status and body, or `nil`
/// when nothing came back. A seam, so no test can reach the network; the
/// real one is `LRCLIBService.fetch`, handed over by `configureForRealLaunch`.
typealias LyricsFetch = @Sendable (URL) async -> (status: Int, body: Data)?

/// Keeps the lyrics line in time with the music -- one request per track,
/// one wake per line (spec 2026-10-29).
///
/// **What runs, and when.** Off, nothing: no request and no wake, and the
/// track is merely remembered so switching on can look it up. On, a new track
/// is looked up once (once more after a pause when the service is busy),
/// and the answer is kept for the session.
/// While a track with synced lyrics plays, there is exactly one pending
/// one-shot, sleeping until the instant the line changes -- the timer's shape
/// (ARCHITECTURE.md, "Allowed, with the timer as the precedent"). A pause, a
/// seek or a new track republishes the position, and the one-shot is
/// replaced from it. Nothing is scheduled or asked outside `.active`.
@MainActor
final class LyricsController {

    /// The words to draw, or `nil` for no lyrics. Published only when they
    /// change. Wired to `AppState`.
    var onChange: ((LyricsText?) -> Void)?

    /// Overridable so tests pin the instant, the way the calendar's is.
    var now: () -> Date = { Date() }

    /// How the one-shots wait. Overridable so a test records the delay and
    /// decides whether it ever returns, rather than waiting out a real one.
    var sleep: @Sendable (Duration) async -> Void = { duration in
        try? await Task.sleep(for: duration)
    }

    /// How long a busy or unreachable service is given before the one retry.
    static let retryDelay: Duration = .seconds(4)

    private let fetch: LyricsFetch

    private(set) var isEnabled = false
    private var activity: SystemActivity = .active

    /// The last track reported, kept while off so switching on can use it.
    private var track: TrackSnapshot?
    /// What the current track is looked up by, or `nil` when it cannot be.
    private var query: LyricsQuery?
    /// The current track's lyrics, once found.
    private var lyrics: SyncedLyrics?
    /// The key whose lookup failed twice; not asked again until the track
    /// changes, so an outage costs two requests, not two per unlock.
    private var gaveUp: String?
    private var cache = LyricsCache()

    /// The request in flight, the parked retry, and the one pending wake.
    /// Exposed so tests can prove there is never more than one of each, and
    /// none while off or locked.
    private(set) var lookupTask: Task<Void, Never>?
    private(set) var retryTask: Task<Void, Never>?
    private(set) var boundaryTask: Task<Void, Never>?
    private(set) var scheduledBoundary: Date?

    /// What was last handed to `onChange`, so an unchanged line -- every
    /// pause, seek and play mid-line -- is not a redraw.
    private var published: LyricsText?

    var cachedAnswers: Int { cache.count }

    init(fetch: @escaping LyricsFetch) {
        self.fetch = fetch
    }

    // MARK: - Lifecycle

    func setEnabled(_ enabled: Bool) {
        guard enabled else {
            stop()
            return
        }
        guard !isEnabled else { return }
        isEnabled = true
        trackDidChange(track)
    }

    /// Cancels the request, the retry and the wake, forgets every answer and
    /// withdraws the line: off holds nothing.
    func stop() {
        isEnabled = false
        cancelLookup()
        cancelBoundary()
        cache.removeAll()
        query = nil
        lyrics = nil
        gaveUp = nil
        publish(nil)
    }

    /// Outside `.active` nobody can see the line: the wake and any request
    /// go, and both come back on return.
    func setActivity(_ next: SystemActivity) {
        activity = next
        guard isEnabled else { return }
        if next == .active {
            lookUpIfNeeded()
            refresh(at: now())
        } else {
            cancelLookup()
            cancelBoundary()
        }
    }

    // MARK: - The track

    /// Every change the media module publishes: a new track, play, pause, a
    /// seek, or nothing playing.
    func trackDidChange(_ snapshot: TrackSnapshot?) {
        track = snapshot
        guard isEnabled else { return }
        let next = snapshot.flatMap {
            LyricsQuery(title: $0.title, artist: $0.artist, duration: $0.position?.duration)
        }
        if next?.key != query?.key {
            query = next
            lyrics = next.flatMap { cache.answer(for: $0.key)?.lyrics }
            gaveUp = nil
            cancelLookup()
            lookUpIfNeeded()
        }
        refresh(at: now())
    }

    // MARK: - Looking up

    private func lookUpIfNeeded() {
        guard isEnabled, activity == .active, let query, lookupTask == nil, retryTask == nil,
              gaveUp != query.key, cache.answer(for: query.key) == nil
        else { return }
        lookUp(query, isRetry: false)
    }

    private func lookUp(_ query: LyricsQuery, isRetry: Bool) {
        let fetch = self.fetch
        lookupTask = Task { [weak self] in
            let answer = await Self.ask(query, fetch: fetch)
            guard !Task.isCancelled else { return }
            self?.answered(answer, for: query, isRetry: isRetry)
        }
    }

    private static func ask(_ query: LyricsQuery, fetch: LyricsFetch) async -> LyricsAnswer {
        guard !Task.isCancelled, let reply = await fetch(query.request) else {
            return .unavailable
        }
        return LyricsAnswer(status: reply.status, body: reply.body)
    }

    private func answered(_ answer: LyricsAnswer, for asked: LyricsQuery, isRetry: Bool) {
        lookupTask = nil
        guard isEnabled else { return }
        cache.store(answer, for: asked.key)
        // The track may have changed while the request was out; the answer
        // is still worth keeping, but not worth showing.
        guard asked.key == query?.key else { return }
        switch answer {
        case .found(let found):
            lyrics = found
            refresh(at: now())
        case .none:
            break
        case .unavailable:
            if isRetry {
                gaveUp = asked.key
            } else {
                let sleep = self.sleep
                retryTask = Task { [weak self] in
                    await sleep(Self.retryDelay)
                    guard !Task.isCancelled else { return }
                    self?.retryReached()
                }
            }
        }
    }

    /// The pause after a busy answer is over: the one retry. Internal so a
    /// test can arrive without waiting four seconds.
    func retryReached() {
        retryTask?.cancel()
        retryTask = nil
        guard isEnabled, activity == .active, let query, lookupTask == nil else { return }
        lookUp(query, isRetry: true)
    }

    private func cancelLookup() {
        lookupTask?.cancel()
        lookupTask = nil
        retryTask?.cancel()
        retryTask = nil
    }

    // MARK: - Keeping time

    /// Publishes the line for `instant` and schedules the wake for the next.
    private func refresh(at instant: Date) {
        cancelBoundary()
        guard isEnabled, let lyrics, let track, let position = track.position else {
            publish(nil)
            return
        }
        let frame = lyrics.frame(position: position, isPlaying: track.isPlaying, at: instant)
        publish(frame.text)
        guard activity == .active, let next = frame.nextChangeAt else { return }
        schedule(next)
    }

    private func schedule(_ boundary: Date) {
        scheduledBoundary = boundary
        let delay = max(boundary.timeIntervalSince(now()), 0)
        let sleep = self.sleep
        boundaryTask = Task { [weak self] in
            await sleep(.milliseconds(Int64((delay * 1000).rounded(.up))))
            guard !Task.isCancelled else { return }
            self?.boundaryReached()
        }
    }

    /// The line's instant has arrived. Read at the boundary rather than at
    /// the clock, so a wake a hair early still lands on the new line instead
    /// of redrawing the old one and sleeping for a few microseconds.
    /// Internal so a test can arrive without waiting.
    func boundaryReached() {
        let boundary = scheduledBoundary ?? now()
        boundaryTask = nil
        refresh(at: max(now(), boundary))
    }

    private func cancelBoundary() {
        boundaryTask?.cancel()
        boundaryTask = nil
        scheduledBoundary = nil
    }

    private func publish(_ text: LyricsText?) {
        guard text != published else { return }
        published = text
        onChange?(text)
    }
}
