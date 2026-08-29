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

    /// The whole point of dropping `contentID` from identity: a later
    /// task's helper measured it changing on every play/pause for the SAME
    /// track. If identity still preferred it, the artwork cache would miss
    /// on every pause — the exact flicker this module exists to prevent.
    @Test func sameTitleArtistAlbumIsTheSameTrackRegardlessOfContentID() {
        let a = TrackIdentity(payload: payload(title: "X", id: "one"))
        let b = TrackIdentity(payload: payload(title: "X", id: "two"))
        #expect(a == b)
    }

    /// Not every player supplies a content id — and it is not used anyway —
    /// so title, artist, and album are what the cache keys on. Without
    /// them every payload would look like a new track and the cache would
    /// never hit.
    @Test func titleAndArtistIdentifyATrackWithNoContentID() {
        let a = TrackIdentity(payload: payload(title: "X", artist: "A", id: nil))
        let b = TrackIdentity(payload: payload(title: "X", artist: "A", id: nil))
        let c = TrackIdentity(payload: payload(title: "Z", artist: "A", id: nil))
        #expect(a == b)
        #expect(a != c)
    }

    /// Title, artist, and album are decoded straight from JSON, so any of
    /// them may legally contain the U+001F separator the key uses to join
    /// them. A bare `"ta:\(title)\(sep)\(artist)\(sep)\(album)"`
    /// concatenation would let title "A<sep>B" / artist "C" produce the
    /// identical key to title "A" / artist "B<sep>C" (same album both
    /// times) — two different tracks colliding on one identity. The key
    /// must disambiguate this, not just make it unlikely.
    @Test func aSeparatorInsideTheTitleCannotForgeACollisionWithADifferentArtist() {
        let titleContainsSeparator = MediaPayload.decode(
            line: "{\"title\":\"A\\u001fB\",\"artist\":\"C\",\"album\":\"\",\"playing\":true}"
        )!
        let artistContainsSeparator = MediaPayload.decode(
            line: "{\"title\":\"A\",\"artist\":\"B\\u001fC\",\"album\":\"\",\"playing\":true}"
        )!

        let a = TrackIdentity(payload: titleContainsSeparator)
        let b = TrackIdentity(payload: artistContainsSeparator)

        #expect(a != b)
    }

    /// The same hazard one boundary over: artist "A<sep>B" / album "C"
    /// must not collide with artist "A" / album "B<sep>C" for an identical
    /// title. Without a length prefix on the artist field specifically,
    /// this pair collides even though the title/artist boundary above is
    /// already protected — each boundary needs its own disambiguation.
    @Test func aSeparatorInsideTheArtistCannotForgeACollisionWithADifferentAlbum() {
        let artistContainsSeparator = MediaPayload.decode(
            line: "{\"title\":\"X\",\"artist\":\"A\\u001fB\",\"album\":\"C\",\"playing\":true}"
        )!
        let albumContainsSeparator = MediaPayload.decode(
            line: "{\"title\":\"X\",\"artist\":\"A\",\"album\":\"B\\u001fC\",\"playing\":true}"
        )!

        let a = TrackIdentity(payload: artistContainsSeparator)
        let b = TrackIdentity(payload: albumContainsSeparator)

        #expect(a != b)
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
    /// inherit the previous track's. Differentiated by title rather than
    /// contentID, since identity no longer considers contentID.
    @Test func aDifferentTrackDoesNotInheritArtwork() {
        var cache = MediaArtworkCache()
        cache.absorb(payload(title: "one", artwork: art))

        #expect(cache.artwork(for: TrackIdentity(payload: payload(title: "two"))) == nil)
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

    /// Differentiated by title rather than contentID, since identity no
    /// longer considers contentID.
    @Test func theCacheIsBounded() {
        var cache = MediaArtworkCache()
        for i in 0...(MediaArtworkCache.capacity + 3) {
            cache.absorb(payload(title: "track-\(i)", artwork: art))
        }
        #expect(cache.count <= MediaArtworkCache.capacity)
    }

    /// Differentiated by title rather than contentID, since identity no
    /// longer considers contentID.
    @Test func theOldestEntryIsEvicted() {
        var cache = MediaArtworkCache()
        for i in 0..<MediaArtworkCache.capacity {
            cache.absorb(payload(title: "track-\(i)", artwork: art))
        }
        cache.absorb(payload(title: "newest", artwork: art))

        #expect(cache.artwork(for: TrackIdentity(payload: payload(title: "newest"))) == art)
        #expect(cache.artwork(for: TrackIdentity(payload: payload(title: "track-0"))) == nil)
    }

    /// One absurd image must not become the app's memory profile.
    @Test func anOverSizedImageIsRefused() {
        var cache = MediaArtworkCache()
        let huge = Data(repeating: 1, count: MediaArtworkCache.maxEntryBytes + 1)
        cache.absorb(payload(artwork: huge))

        #expect(cache.artwork(for: TrackIdentity(payload: payload())) == nil)
    }
}
