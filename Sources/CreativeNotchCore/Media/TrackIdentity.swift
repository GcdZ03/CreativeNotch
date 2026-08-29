import Foundation

/// What makes two payloads "the same track".
///
/// `contentID` when the player supplies one — it survives the title
/// changing case or gaining a suffix mid-stream. Title and artist are the
/// fallback, because not every player provides an id, and without a
/// fallback every payload would look like a new track and the artwork
/// cache would never hit.
public struct TrackIdentity: Hashable, Sendable {

    public let key: String

    public init(payload: MediaPayload) {
        if let id = payload.contentID, !id.isEmpty {
            key = "id:\(id)"
        } else {
            key = "ta:\(payload.title)\u{1F}\(payload.artist)"
        }
    }
}
