import Foundation

/// What makes two payloads "the same track".
///
/// Identity is derived from title, artist, and album — never `contentID`.
/// A later task's helper measured `contentID` changing on every
/// play/pause for the SAME track. Preferring it here would churn identity
/// on every pause, miss the artwork cache, and reload or blank the album
/// cover on every play/pause — exactly the flicker the cache exists to
/// prevent.
///
/// Accepted trade-off: two recordings that share title, artist, and album
/// (a live cut and a studio cut released under an identical album name,
/// say) will share one identity. That is a rarer and gentler failure than
/// the flicker `contentID` would cause on every single track.
///
/// The key length-prefixes each variable-length field with its UTF-8 byte
/// count before the separator that follows it:
/// `"ta:\(titleByteCount)\u{1F}\(title)\u{1F}\(artistByteCount)\u{1F}\(artist)\u{1F}\(album)"`.
/// Title, artist, and album are decoded straight from JSON, so any of them
/// may legally contain the U+001F separator itself. A bare concatenation
/// (`"ta:\(title)\u{1F}\(artist)\u{1F}\(album)"`) is therefore ambiguous —
/// e.g. title `"A\u{1F}B"` / artist `"C"` / album `"D"` and title `"A"` /
/// artist `"B\u{1F}C"` / album `"D"` would produce the identical string.
/// Prefixing each field's byte count pins exactly where that field ends,
/// so the two cases above produce different keys because the prefixes
/// themselves disagree. Album is last and does not need its own prefix —
/// nothing follows it for a boundary to be ambiguous about. Do not remove
/// the length prefixes: without them, two different (title, artist, album)
/// triples can collide on the same identity.
public struct TrackIdentity: Hashable, Sendable {

    public let key: String

    public init(payload: MediaPayload) {
        let title = payload.title
        let artist = payload.artist
        key = "ta:\(title.utf8.count)\u{1F}\(title)\u{1F}\(artist.utf8.count)\u{1F}\(artist)\u{1F}\(payload.album)"
    }
}
