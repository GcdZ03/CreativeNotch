import Foundation

/// The four things sent to LRCLIB for one track, and the requests made of
/// them (spec 2026-10-29, "The service").
///
/// This is the whole of what leaves the machine: a title, an artist, an
/// album and a length in whole seconds. No identifier and no history.
public struct LyricsQuery: Equatable, Sendable {
    public let title: String
    public let artist: String
    public let album: String
    public let seconds: Int

    /// `nil` for a track not worth a request: no title or artist to match
    /// by, no length (a live stream), or a length no song has. Under 30s is
    /// a jingle or a preview; over 20 minutes is a podcast or a mix.
    public init?(title: String, artist: String, album: String, duration: TimeInterval?) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !artist.isEmpty,
              let duration, duration.isFinite, duration >= 30, duration <= 20 * 60
        else { return nil }
        self.title = title
        self.artist = artist
        self.album = album.trimmingCharacters(in: .whitespacesAndNewlines)
        self.seconds = Int(duration.rounded())
    }

    /// The cache key. Whole seconds, so two readings of one track that
    /// round alike share an answer.
    public var key: String {
        [title, artist, album, String(seconds)].joined(separator: "\u{1F}")
    }

    /// Measured: a wrong album is a 404 and an empty one is ignored, so a
    /// track with an album is asked about with it first and then without.
    public var requestsAlbumFirst: Bool { !album.isEmpty }

    public func request(withAlbum: Bool) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "lrclib.net"
        components.path = "/api/get"
        components.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "album_name", value: withAlbum ? album : ""),
            URLQueryItem(name: "duration", value: String(seconds)),
        ]
        // Every component above is set, so this cannot be nil.
        return components.url!
    }
}

/// What one request learned.
public enum LyricsAnswer: Equatable, Sendable {
    case found(SyncedLyrics)
    /// The service answered and has nothing synced for this track: not
    /// found, instrumental, or plain lyrics only. Worth remembering.
    case none
    /// The service did not answer the question: overloaded, rate-limited,
    /// down, or unreachable. Says nothing about the track, so never cached.
    case unavailable

    /// The lyrics, when there are some.
    public var lyrics: SyncedLyrics? {
        if case .found(let lyrics) = self { return lyrics }
        return nil
    }

    public init(status: Int, body: Data) {
        switch status {
        case 200:
            struct Body: Decodable { let instrumental: Bool?; let syncedLyrics: String? }
            guard let decoded = try? JSONDecoder().decode(Body.self, from: body) else {
                self = .unavailable
                return
            }
            if decoded.instrumental != true, let lrc = decoded.syncedLyrics, let lyrics = SyncedLyrics(lrc: lrc) {
                self = .found(lyrics)
            } else {
                self = .none
            }
        case 404:
            self = .none
        default:
            self = .unavailable
        }
    }
}

/// The last few answers, least recently used first out. In memory only:
/// a lyrics file per track on disk would be a listening history.
public struct LyricsCache: Sendable {
    public let capacity: Int
    private var answers: [String: LyricsAnswer] = [:]
    private var order: [String] = []

    public init(capacity: Int = 50) {
        self.capacity = capacity
    }

    public var count: Int { answers.count }

    public mutating func answer(for key: String) -> LyricsAnswer? {
        guard let answer = answers[key] else { return nil }
        touch(key)
        return answer
    }

    public mutating func store(_ answer: LyricsAnswer, for key: String) {
        guard answer != .unavailable else { return }
        answers[key] = answer
        touch(key)
        while order.count > capacity {
            answers[order.removeFirst()] = nil
        }
    }

    public mutating func removeAll() {
        answers = [:]
        order = []
    }

    private mutating func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}
