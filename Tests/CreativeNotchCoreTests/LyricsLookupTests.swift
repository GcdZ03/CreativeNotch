import Foundation
import Testing
@testable import CreativeNotchCore

/// What is asked of LRCLIB, and what its answers mean (spec 2026-10-29,
/// "The service" — every status here was seen on 2026-10-29).
struct LyricsLookupTests {

    private func query(title: String = "I Want to Live", duration: Double = 233.4) -> LyricsQuery? {
        LyricsQuery(title: title, artist: "Borislav Slavov", duration: duration)
    }

    // MARK: - What is worth asking about

    @Test func aTrackWithoutATitleArtistOrLengthIsNotLookedUp() {
        #expect(LyricsQuery(title: "", artist: "A", duration: 200) == nil)
        #expect(LyricsQuery(title: "T", artist: "  ", duration: 200) == nil)
        #expect(LyricsQuery(title: "T", artist: "A", duration: nil) == nil)
    }

    /// Too short for a song, or podcast-long: not worth a request.
    @Test func implausibleLengthsAreNotLookedUp() {
        #expect(LyricsQuery(title: "T", artist: "A", duration: 20) == nil)
        #expect(LyricsQuery(title: "T", artist: "A", duration: 60 * 30) == nil)
    }

    /// The service matches whole seconds within about two.
    @Test func theDurationIsRounded() throws {
        #expect(try #require(query(duration: 233.4)).seconds == 233)
        #expect(try #require(query(duration: 233.6)).seconds == 234)
    }

    @Test func twoQueriesForOneTrackShareAKey() throws {
        #expect(try #require(query(duration: 233.1)).key == #require(query(duration: 232.9)).key)
        #expect(try #require(query(title: "A")).key != #require(query(title: "B")).key)
    }

    // MARK: - The requests

    /// Title, artist and length, and nothing else -- the album included
    /// (see `LyricsQuery`).
    @Test func theRequestCarriesTitleArtistAndLengthOnly() throws {
        let url = try #require(query()).request
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(url.scheme == "https")
        #expect(url.host == "lrclib.net")
        #expect(url.path == "/api/get")
        #expect(Set(items) == [
            URLQueryItem(name: "track_name", value: "I Want to Live"),
            URLQueryItem(name: "artist_name", value: "Borislav Slavov"),
            URLQueryItem(name: "duration", value: "233"),
        ])
    }

    // MARK: - The answers

    @Test func syncedLyricsAreFound() throws {
        let body = Data(#"{"instrumental":false,"syncedLyrics":"[00:01.00] Hi","plainLyrics":"Hi"}"#.utf8)
        #expect(LyricsAnswer(status: 200, body: body) == .found(SyncedLyrics(lines: [LyricLine(time: 1, text: "Hi")])))
    }

    /// Plain lyrics alone cannot be synced, so they count as none.
    @Test func plainLyricsAloneAreNone() {
        let body = Data(#"{"instrumental":false,"syncedLyrics":null,"plainLyrics":"Hi"}"#.utf8)
        #expect(LyricsAnswer(status: 200, body: body) == .none)
    }

    @Test func anInstrumentalIsNone() {
        let body = Data(#"{"instrumental":true,"syncedLyrics":null,"plainLyrics":null}"#.utf8)
        #expect(LyricsAnswer(status: 200, body: body) == .none)
    }

    @Test func notFoundIsNone() {
        let body = Data(#"{"message":"Failed to find specified track","name":"TrackNotFound","statusCode":404}"#.utf8)
        #expect(LyricsAnswer(status: 404, body: body) == .none)
    }

    /// `503 ServerOverloaded` happened several times in a row on
    /// 2026-10-29. It says nothing about the track, so it is not remembered.
    @Test func busyIsWorthOneMoreTry() {
        let body = Data(#"{"message":"The server is busy, please retry in a moment","name":"ServerOverloaded","statusCode":503}"#.utf8)
        #expect(LyricsAnswer(status: 503, body: body) == .unavailable)
        #expect(LyricsAnswer(status: 429, body: Data()) == .unavailable)
        #expect(LyricsAnswer(status: 500, body: Data()) == .unavailable)
    }

    @Test func aGarbledOkIsUnavailableNotNone() {
        #expect(LyricsAnswer(status: 200, body: Data("<html>".utf8)) == .unavailable)
    }
}

/// The last fifty answers, in memory only (spec 2026-10-29, "What is kept").
struct LyricsCacheTests {

    private let found = LyricsAnswer.found(SyncedLyrics(lines: [LyricLine(time: 1, text: "a")]))

    @Test func remembersFoundAndNone() {
        var cache = LyricsCache(capacity: 3)
        cache.store(found, for: "a")
        cache.store(.none, for: "b")
        #expect(cache.answer(for: "a") == found)
        #expect(cache.answer(for: "b") == LyricsAnswer.none)
        #expect(cache.answer(for: "c") == nil)
    }

    /// An outage is not an answer about the track.
    @Test func neverRemembersUnavailable() {
        var cache = LyricsCache(capacity: 3)
        cache.store(.unavailable, for: "a")
        #expect(cache.answer(for: "a") == nil)
    }

    @Test func dropsTheLeastRecentlyUsed() {
        var cache = LyricsCache(capacity: 2)
        cache.store(.none, for: "a")
        cache.store(.none, for: "b")
        _ = cache.answer(for: "a")          // a is now the most recent
        cache.store(.none, for: "c")
        #expect(cache.answer(for: "a") != nil)
        #expect(cache.answer(for: "b") == nil)
        #expect(cache.answer(for: "c") != nil)
    }

    @Test func clearForgetsEverything() {
        var cache = LyricsCache(capacity: 2)
        cache.store(found, for: "a")
        cache.removeAll()
        #expect(cache.answer(for: "a") == nil)
        #expect(cache.count == 0)
    }
}
