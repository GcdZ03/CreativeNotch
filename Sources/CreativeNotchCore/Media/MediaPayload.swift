import Foundation

/// One line of the helper's newline-delimited JSON.
///
/// Decoding is total: any line either produces a payload or `nil`, and
/// nothing here can trap. The helper is a subprocess reading a private
/// framework, and its output is the least trustworthy input in the app —
/// stderr diagnostics can appear, a pipe can truncate, and a future macOS
/// can change what MediaRemote returns.
///
/// Text fields default to empty rather than failing the whole line. A
/// track with no album is ordinary, and losing the title because the album
/// was absent would be a bad trade.
public struct MediaPayload: Equatable, Sendable, Decodable {

    public var title: String
    public var artist: String
    public var album: String
    public var isPlaying: Bool
    public var contentID: String?

    /// Base64 as it arrives on the wire. Kept encoded until asked for, so
    /// decoding a payload never allocates an image-sized buffer.
    public var artworkBase64: String?

    private enum CodingKeys: String, CodingKey {
        case title, artist, album, contentID
        case isPlaying = "playing"
        case artworkBase64 = "artwork"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        artist = try c.decodeIfPresent(String.self, forKey: .artist) ?? ""
        album = try c.decodeIfPresent(String.self, forKey: .album) ?? ""
        isPlaying = try c.decodeIfPresent(Bool.self, forKey: .isPlaying) ?? false
        contentID = try c.decodeIfPresent(String.self, forKey: .contentID)
        artworkBase64 = try c.decodeIfPresent(String.self, forKey: .artworkBase64)
    }

    /// Decoded artwork, or `nil` if absent or unusable.
    ///
    /// Invalid base64 yields `nil` rather than failing the payload: the
    /// title and artist are still worth showing, and the spike proved
    /// artwork is unreliable by nature.
    public var artwork: Data? {
        guard let artworkBase64 else { return nil }
        return Data(base64Encoded: artworkBase64)
    }

    /// The part of this payload the rest of the app models.
    ///
    /// `isPlaying` comes from the payload's own playback rate rather than
    /// from notification ordering — the spike saw `playing` lag the real
    /// state in the first notifications after a change.
    ///
    /// A payload with no title describes no track: that is how "nothing is
    /// playing" arrives, and it becomes `nil` rather than an empty header.
    public var snapshot: TrackSnapshot? {
        guard !title.isEmpty || !artist.isEmpty else { return nil }
        return TrackSnapshot(title: title, artist: artist, isPlaying: isPlaying)
    }

    /// Returns `nil` for anything that is not a JSON object — including
    /// the helper's own stderr diagnostics, should they ever be routed
    /// here by mistake.
    public static func decode(line: String) -> MediaPayload? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(MediaPayload.self, from: data)
    }
}
