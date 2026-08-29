import Foundation
import Testing
@testable import CreativeNotchCore

/// Artwork keyed by track identity.
///
/// The spike found artwork flapping present/absent across consecutive
/// emissions for ONE unchanged song: 138061 → 0 → 0 → 138061 → 138061 → 0
/// → 138061. Clearing the art whenever a payload omits it would flicker
/// the album cover several times per play/pause. This type is the reason
/// that never reaches the screen.
struct MediaArtworkCacheTests {

    private func payload(
        title: String = "T",
        artist: String = "A",
        id: String? = "id-1",
        artwork: Data? = nil
    ) -> MediaPayload {
        var json = "{\"title\":\"\(title)\",\"artist\":\"\(artist)\",\"album\":\"\",\"playing\":true"
        if let id { json += ",\"contentID\":\"\(id)\"" }
        if let artwork { json += ",\"artwork\":\"\(artwork.base64EncodedString())\"" }
        json += "}"
        return MediaPayload.decode(line: json)!
    }

    private let art = Data(repeating: 7, count: 1024)

    // MARK: - Identity

    @Test func contentIDIdentifiesTheTrack() {
        let a = TrackIdentity(payload: payload(title: "X", id: "same"))
        let b = TrackIdentity(payload: payload(title: "Y", id: "same"))
        #expect(a == b)
    }

    /// Not every player supplies a content id, so title+artist is the
    /// fallback — without it, every payload would look like a new track and
    /// the cache would never hit.
    @Test func titleAndArtistIdentifyATrackWithNoContentID() {
        let a = TrackIdentity(payload: payload(title: "X", artist: "A", id: nil))
        let b = TrackIdentity(payload: payload(title: "X", artist: "A", id: nil))
        let c = TrackIdentity(payload: payload(title: "Z", artist: "A", id: nil))
        #expect(a == b)
        #expect(a != c)
    }

    // MARK: - The rule this type exists for

    @Test func artworkIsRememberedForTheTrack() {
        var cache = MediaArtworkCache()
        let p = payload(artwork: art)
        cache.absorb(p)

        #expect(cache.artwork(for: TrackIdentity(payload: p)) == art)
    }

    /// The whole point. A later payload for the SAME track with no artwork
    /// must not erase what we already have.
    @Test func aLaterPayloadWithoutArtworkDoesNotClearIt() {
        var cache = MediaArtworkCache()
        cache.absorb(payload(artwork: art))
        cache.absorb(payload(artwork: nil))

        #expect(cache.artwork(for: TrackIdentity(payload: payload())) == art)
    }

    /// Replays the exact sequence the spike measured, then goes one step
    /// further.
    ///
    /// The observed run itself ends on an artwork-present emission, so
    /// asserting right after it proves nothing about the never-clear rule —
    /// the last `absorb` call would restock the artwork regardless of
    /// whether omission clears it. The assertion only becomes load-bearing
    /// once it lands after an omission, so one further no-artwork payload is
    /// absorbed past the measured sequence before checking.
    @Test func theObservedFlapSequenceKeepsTheArtwork() {
        var cache = MediaArtworkCache()
        for present in [true, false, false, true, true, false, true] {
            cache.absorb(payload(artwork: present ? art : nil))
        }
        cache.absorb(payload(artwork: nil))
        #expect(cache.artwork(for: TrackIdentity(payload: payload())) == art)
    }

    /// A different track legitimately has different art, and must not
    /// inherit the previous track's.
    @Test func aDifferentTrackDoesNotInheritArtwork() {
        var cache = MediaArtworkCache()
        cache.absorb(payload(id: "one", artwork: art))

        #expect(cache.artwork(for: TrackIdentity(payload: payload(id: "two"))) == nil)
    }

    /// Fresh artwork for a track we already know replaces the old — album
    /// art can legitimately change resolution mid-playback.
    @Test func newerArtworkForTheSameTrackReplacesIt() {
        var cache = MediaArtworkCache()
        let bigger = Data(repeating: 9, count: 2048)
        cache.absorb(payload(artwork: art))
        cache.absorb(payload(artwork: bigger))

        #expect(cache.artwork(for: TrackIdentity(payload: payload())) == bigger)
    }

    // MARK: - Bounds

    @Test func theCacheIsBounded() {
        var cache = MediaArtworkCache()
        for i in 0...(MediaArtworkCache.capacity + 3) {
            cache.absorb(payload(id: "track-\(i)", artwork: art))
        }
        #expect(cache.count <= MediaArtworkCache.capacity)
    }

    @Test func theOldestEntryIsEvicted() {
        var cache = MediaArtworkCache()
        for i in 0..<MediaArtworkCache.capacity {
            cache.absorb(payload(id: "track-\(i)", artwork: art))
        }
        cache.absorb(payload(id: "newest", artwork: art))

        #expect(cache.artwork(for: TrackIdentity(payload: payload(id: "newest"))) == art)
        #expect(cache.artwork(for: TrackIdentity(payload: payload(id: "track-0"))) == nil)
    }

    /// One absurd image must not become the app's memory profile.
    @Test func anOverSizedImageIsRefused() {
        var cache = MediaArtworkCache()
        let huge = Data(repeating: 1, count: MediaArtworkCache.maxEntryBytes + 1)
        cache.absorb(payload(artwork: huge))

        #expect(cache.artwork(for: TrackIdentity(payload: payload())) == nil)
    }
}
