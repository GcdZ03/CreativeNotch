import Foundation

/// What makes two payloads "the same track".
///
/// `contentID` when the player supplies one — it survives the title
/// changing case or gaining a suffix mid-stream. Title and artist are the
/// fallback, because not every player provides an id, and without a
/// fallback every payload would look like a new track and the artwork
/// cache would never hit.
///
/// The fallback key is length-prefixed with the title's UTF-8 byte count
/// before the first separator: `"ta:\(titleByteCount)\u{1F}\(title)\u{1F}\(artist)"`.
/// Title and artist come straight from decoded JSON, so either string may
/// legally contain the U+001F separator itself. A bare
/// `"ta:\(title)\u{1F}\(artist)"` concatenation is therefore ambiguous —
/// title `"A\u{1F}B"` with artist `"C"` and title `"A"` with artist
/// `"B\u{1F}C"` produce the identical string. Prefixing with the title's
/// byte count pins where the title ends, so the two cases above produce
/// `ta:3\u{1F}A\u{1F}B\u{1F}C` and `ta:1\u{1F}A\u{1F}B\u{1F}C` respectively
/// — different keys, because the prefix itself disagrees. Do not remove
/// the length prefix: without it, two different (title, artist) pairs can
/// collide on the same identity.
public struct TrackIdentity: Hashable, Sendable {

    public let key: String

    public init(payload: MediaPayload) {
        if let id = payload.contentID, !id.isEmpty {
            key = "id:\(id)"
        } else {
            let title = payload.title
            key = "ta:\(title.utf8.count)\u{1F}\(title)\u{1F}\(payload.artist)"
        }
    }
}
