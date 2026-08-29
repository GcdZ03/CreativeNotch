import Foundation
import Testing
@testable import CreativeNotchCore

/// One line of the helper's newline-delimited JSON.
///
/// This is the boundary between an untrusted byte stream and everything
/// downstream, so it has to survive anything the helper — or a corrupted
/// pipe — can emit, and never trap.
struct MediaPayloadTests {

    private let full = #"{"title":"Beauty And A Beat","artist":"Justin Bieber","album":"Believe","playing":true,"contentID":"E398464F","artwork":"QUJD"}"#

    @Test func aCompleteLineDecodes() throws {
        let p = try #require(MediaPayload.decode(line: full))
        #expect(p.title == "Beauty And A Beat")
        #expect(p.artist == "Justin Bieber")
        #expect(p.album == "Believe")
        #expect(p.isPlaying)
        #expect(p.contentID == "E398464F")
        #expect(p.artwork == Data("ABC".utf8))
    }

    /// The spike observed artwork present in one emission and absent in the
    /// next for the same track. An absent field is normal, not an error.
    @Test func anAbsentArtworkFieldIsNotAFailure() throws {
        let line = #"{"title":"T","artist":"A","album":"","playing":false}"#
        let p = try #require(MediaPayload.decode(line: line))
        #expect(p.artwork == nil)
        #expect(p.title == "T")
    }

    /// Missing text fields default to empty rather than failing the line —
    /// a track with no album is ordinary.
    @Test func missingTextFieldsDefaultToEmpty() throws {
        let p = try #require(MediaPayload.decode(line: #"{"playing":true}"#))
        #expect(p.title.isEmpty)
        #expect(p.artist.isEmpty)
        #expect(p.isPlaying)
    }

    @Test func malformedJSONYieldsNil() {
        #expect(MediaPayload.decode(line: "not json") == nil)
        #expect(MediaPayload.decode(line: "") == nil)
        #expect(MediaPayload.decode(line: "{") == nil)
        #expect(MediaPayload.decode(line: "[]") == nil)
    }

    /// The helper writes stderr diagnostics too. If those ever reach the
    /// stdout reader they must be dropped, not crash it.
    @Test func nonJSONDiagnosticLinesYieldNil() {
        #expect(MediaPayload.decode(line: "[stream] registered") == nil)
    }

    @Test func invalidBase64ArtworkIsIgnoredRatherThanFatal() throws {
        let line = #"{"title":"T","artist":"A","album":"","playing":true,"artwork":"!!!not base64!!!"}"#
        let p = try #require(MediaPayload.decode(line: line))
        #expect(p.artwork == nil)
        #expect(p.title == "T")
    }

    /// Titles contain quotes, emoji and non-Latin scripts. The spike's own
    /// test track was "跳楼机".
    @Test func unicodeAndQuotesSurvive() throws {
        let line = #"{"title":"跳楼机 \"live\"","artist":"歌手","album":"","playing":true}"#
        let p = try #require(MediaPayload.decode(line: line))
        #expect(p.title == "跳楼机 \"live\"")
        #expect(p.artist == "歌手")
    }
}
