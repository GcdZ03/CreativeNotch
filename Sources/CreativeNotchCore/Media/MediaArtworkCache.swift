import Foundation

/// Artwork, remembered per track.
///
/// **Absorbing a payload with no artwork never clears what is stored.**
/// The spike measured artwork flapping present/absent across consecutive
/// emissions for one unchanged song — `138061 → 0 → 0 → 138061 → 138061 →
/// 0 → 138061`. Clearing on omission would flicker the album cover several
/// times per play/pause, and the cause would be invisible from the UI code
/// where the symptom appears.
///
/// Bounded on both axes: a handful of recent tracks, and a ceiling per
/// image. Artwork is the only unbounded thing the helper can hand us.
public struct MediaArtworkCache: Equatable, Sendable {

    /// Enough to cover skipping back and forth through a few tracks.
    public static let capacity = 8

    /// 5 MB. Real cover art is tens to hundreds of kilobytes; anything at
    /// this size is a bug somewhere upstream, not a picture worth showing.
    public static let maxEntryBytes = 5_000_000

    private var entries: [(identity: TrackIdentity, artwork: Data)] = []

    public init() {}

    public var count: Int { entries.count }

    public static func == (lhs: MediaArtworkCache, rhs: MediaArtworkCache) -> Bool {
        lhs.entries.map(\.identity) == rhs.entries.map(\.identity)
            && lhs.entries.map(\.artwork) == rhs.entries.map(\.artwork)
    }

    /// Takes whatever this payload offers, and keeps everything it does not.
    public mutating func absorb(_ payload: MediaPayload) {
        guard let artwork = payload.artwork,
              !artwork.isEmpty,
              artwork.count <= Self.maxEntryBytes
        else { return }   // <- the never-clear rule, in one `return`

        let identity = TrackIdentity(payload: payload)
        entries.removeAll { $0.identity == identity }
        entries.append((identity, artwork))

        while entries.count > Self.capacity {
            entries.removeFirst()
        }
    }

    public func artwork(for identity: TrackIdentity) -> Data? {
        entries.last { $0.identity == identity }?.artwork
    }
}
