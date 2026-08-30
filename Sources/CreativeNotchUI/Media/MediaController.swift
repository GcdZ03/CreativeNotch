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
    private var hasSeenHealthyLine = false

    /// Identity of the currently-published `snapshot`, computed from the
    /// full payload (title, artist, AND album) at the moment it was
    /// accepted. `TrackSnapshot` itself carries no album, so this is kept
    /// alongside it rather than recomputed from the snapshot later — doing
    /// that would silently drop the album component of identity and could
    /// fetch a different track's artwork for two same-titled, same-artist
    /// tracks released under different album names.
    private var currentIdentity: TrackIdentity?

    public init() {}

    public func start() {
        hasSeenHealthyLine = false
        supervisor.onLine = { [weak self] line in self?.handle(line: line) }
        supervisor.start()
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

        // The helper produced a decodable line, so it is healthy. This
        // must happen for every line, not just ones that change state —
        // see `MediaHelperSupervisor.noteHealthy()`'s doc comment: a
        // long-lived helper that has been silently repeating the same
        // state for an hour is not owed a crash-loop cap built from
        // attempts made before it proved itself.
        if !hasSeenHealthyLine {
            hasSeenHealthyLine = true
            supervisor.noteHealthy()
        }

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
