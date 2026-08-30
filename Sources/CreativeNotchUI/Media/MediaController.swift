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
/// Absorbing first is necessary but not sufficient: `TrackSnapshot` has no
/// artwork field (deliberately — see `currentIdentity`'s doc comment), so
/// `coalescer.accept` can only ever say the SNAPSHOT changed, never that the
/// artwork did. A line that repeats an already-published snapshot but is
/// the first to carry artwork for it would still be dropped as a duplicate,
/// and the cache would hold the picture forever while nothing ever asked it
/// to redraw. `handle(line:)` therefore has a second, narrower path for
/// exactly that case: when `coalescer.accept` says no, it still checks
/// whether the artwork cached for the identity already on screen differs
/// from `lastPublishedArtwork`, and republishes the (unchanged) snapshot
/// only then. This must stay narrow — gated on the identity matching what
/// is currently published, and on the artwork bytes actually differing —
/// or it degenerates into "publish on every line", which is the exact
/// burst-multiplication problem `MediaCoalescer` exists to prevent.
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

    /// The artwork bytes last handed to `onChange` for `currentIdentity`,
    /// so a later line that finally carries (or changes) artwork for the
    /// track already on screen can be told apart from one that doesn't.
    ///
    /// This is deliberately NOT part of `TrackSnapshot` or `MediaCoalescer`
    /// — see this type's doc comment. Comparing `Data?` is fine here: it
    /// runs a handful of times per user action, not in a loop, and `Data`
    /// equality short-circuits on `count` before touching bytes.
    private var lastPublishedArtwork: Data?

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
        lastPublishedArtwork = nil
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

        // Every decodable line reports in here, unconditionally — but
        // whether that resets the attempt budget is `noteHealthy()`'s
        // decision, not this call site's. It used to be: this controller
        // tried to encode "is the helper healthy" itself (first a
        // once-ever latch, then "any line at all"), and got it wrong both
        // times — see `MediaHelperSupervisor.noteHealthy()`'s doc comment
        // for why neither works. That judgement now lives entirely in the
        // supervisor, which is what actually knows when the current
        // helper was spawned.
        supervisor.noteHealthy()

        // Absorb artwork into the cache BEFORE coalescing. See this
        // type's doc comment for why the order cannot be swapped.
        artworkCache.absorb(payload)

        let candidate = payload.snapshot

        if coalescer.accept(candidate) {
            // The snapshot itself changed (including "started"/"stopped"
            // transitions) — publish unconditionally, and record whatever
            // artwork the cache holds for the new identity right now so a
            // later duplicate line can tell whether artwork changed since.
            snapshot = candidate
            currentIdentity = candidate == nil ? nil : TrackIdentity(payload: payload)
            lastPublishedArtwork = currentIdentity.flatMap { artworkCache.artwork(for: $0) }
            onChange?(candidate)
            return
        }

        // The snapshot is an exact duplicate of what's already published —
        // title/artist/isPlaying unchanged — so the coalescer alone would
        // drop this line. But this is exactly the shape the bug report
        // described: a later line for the SAME track that finally carries
        // artwork the earlier one omitted. Republish only when the artwork
        // for the currently-shown identity actually changed, so a burst of
        // truly-identical lines (same snapshot, same or absent artwork)
        // still collapses to the one publish the coalescer exists to give.
        guard let currentIdentity,
              candidate != nil,
              TrackIdentity(payload: payload) == currentIdentity
        else { return }

        let latestArtwork = artworkCache.artwork(for: currentIdentity)
        guard latestArtwork != lastPublishedArtwork else { return }

        lastPublishedArtwork = latestArtwork
        onChange?(snapshot)
    }
}
