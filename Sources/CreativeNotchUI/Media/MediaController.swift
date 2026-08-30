import AppKit
import CreativeNotchCore

/// Turns the helper's newline-delimited JSON stream into published
/// now-playing state.
///
/// Shaped after `HUDController` and `ClipboardController`: `MediaHelperSupervisor`
/// is a dumb source (it only decides *whether* the helper runs and hands
/// back raw lines), and every judgement about what those lines *mean* lives
/// here, where a test can drive it directly through `handle(line:)` without
/// spawning anything.
///
/// The order inside `handle(line:)` is load-bearing:
/// decode → absorb artwork into the cache → coalesce → publish if accepted.
/// Artwork MUST be absorbed before coalescing. If a payload is identical to
/// the last one except that it finally carries artwork, coalescing first
/// would drop it as a duplicate and the album art would never arrive — the
/// cache would hold it, but nothing would ever re-render to show it. See
/// `MediaControllerTests.artworkSurvivesPayloadsThatOmitIt`, and the
/// mutation note in Step 3 of this task's brief.
///
/// Coalescing here is deliberately **last-arrival-wins**, not
/// **last-state-wins**. Task 6's review found that the bridge makes two
/// nested asynchronous XPC calls per notification; its serial queue
/// prevents interleaved bytes on one line, but not a later line's reply
/// arriving before an earlier line's reply, so a stale line can land after
/// a fresher one. `MediaCoalescer.accept` only dedupes against the last
/// *accepted* snapshot — it does not know or care which line is "newer" —
/// and that is intentional. Do NOT bolt a timestamp or sequence-number
/// check on top to try to "correct" arrival order: there is no reliable
/// ordering signal available here to correct it with, and adding one would
/// just be a second, untested guess layered on top of a working one.
@MainActor
public final class MediaController {

    public private(set) var snapshot: TrackSnapshot?
    public var onChange: ((TrackSnapshot?) -> Void)?

    /// Internal rather than private so the lifecycle is provable, the way
    /// `HUDController` exposes its observers and `ClipboardController`
    /// exposes its poller.
    let supervisor = MediaHelperSupervisor()

    private var coalescer = MediaCoalescer()
    private var artworkCache = MediaArtworkCache()

    /// Identity of the currently-published `snapshot`, computed from the
    /// full payload (title, artist, AND album) at the moment it was
    /// accepted. `TrackSnapshot` itself carries no album, so this is kept
    /// alongside it rather than recomputed from the snapshot later — doing
    /// that would silently drop the album component of identity and could
    /// fetch a different track's artwork for two same-titled, same-artist
    /// tracks released under different album names.
    private var currentIdentity: TrackIdentity?

    public init() {
        // Wired in `init`, not `start()`, because `setActivity(.active)`
        // reaches the supervisor without passing through `start()` — and a
        // degrade nobody publishes leaves a stale header on screen for the
        // rest of the session.
        supervisor.onDegraded = { [weak self] in self?.degrade() }
    }

    public func start() {
        supervisor.onLine = { [weak self] line in self?.handle(line: line) }
        supervisor.start()
    }

    /// The helper has failed its way past the retry cap and will not be
    /// started again: publish "nothing playing".
    ///
    /// Without this the last snapshot stayed on screen forever — the panel
    /// kept a header for a track that may have ended hours ago, and hover
    /// kept peeking it, because nothing else ever clears `snapshot`. Spec
    /// section 5 is explicit that a degraded module shows no header.
    ///
    /// The coalescer is reset rather than asked: it would otherwise dedupe
    /// this `nil` against an earlier published `nil` and swallow the very
    /// update that clears the screen. Resetting also means a later restart
    /// — a new `MediaController`, or the activity gate cycling — republishes
    /// its first snapshot instead of comparing it against a dead helper's
    /// last one.
    func degrade() {
        coalescer = MediaCoalescer()
        snapshot = nil
        currentIdentity = nil
        onChange?(nil)
    }

    public func stop() {
        supervisor.stop()
    }

    /// The activity gate reaches the helper through here, the same shape
    /// as `ClipboardController.setActivity(_:now:)` — spec section 4.7:
    /// nothing runs outside `.active`.
    public func setActivity(_ activity: SystemActivity) {
        switch activity {
        case .active:
            supervisor.start()
        case .locked, .asleep:
            supervisor.stop()
        }
    }

    /// Artwork for a snapshot currently being shown, if any was ever seen
    /// for that track's identity.
    ///
    /// Only answers for the snapshot currently published: identity needs
    /// the album too (see `currentIdentity`'s doc comment), which this
    /// method's `TrackSnapshot` parameter cannot supply, so a snapshot
    /// that no longer matches what is published has no identity to look
    /// up here.
    public func artwork(for snapshot: TrackSnapshot) -> Data? {
        guard snapshot == self.snapshot, let currentIdentity else { return nil }
        return artworkCache.artwork(for: currentIdentity)
    }

    /// Decodes one line from the helper and, if it changes anything worth
    /// showing, publishes it.
    ///
    /// Never logs `line`'s contents — titles and artists are user data.
    func handle(line: String) {
        guard let payload = MediaPayload.decode(line: line) else { return }

        // The helper produced a decodable line, so it is healthy. Every
        // line, unconditionally — see `MediaHelperSupervisor.noteHealthy()`:
        // a long-lived helper that dies much later is not the fifth
        // failure of a crash loop and is owed a fresh attempt budget.
        //
        // This used to latch on a `hasSeenHealthyLine` flag, which meant
        // `noteHealthy()` fired exactly once in the controller's life and
        // the supervisor's contract was honoured only until the first
        // crash: five crashes spread over five days would then degrade the
        // module as if they had been a tight loop. `attempt = 0` is a
        // single store — there is nothing to save by skipping it.
        supervisor.noteHealthy()

        // Absorb artwork into the cache BEFORE coalescing. See this
        // type's doc comment for why the order cannot be swapped.
        artworkCache.absorb(payload)

        let candidate = payload.snapshot
        guard coalescer.accept(candidate) else { return }

        snapshot = candidate
        currentIdentity = candidate == nil ? nil : TrackIdentity(payload: payload)
        onChange?(candidate)
    }
}
