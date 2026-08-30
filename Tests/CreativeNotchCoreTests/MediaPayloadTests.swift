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

    // MARK: - `snapshot` — the module's "is anything playing" rule

    /// The single predicate that decides whether anything is playing, and
    /// until now nothing tested it directly: changing
    /// `!title.isEmpty || !artist.isEmpty` to `&&` left all 525 tests
    /// green. It was reached only through `MediaControllerTests`, every one
    /// of which uses a payload carrying both fields. (Follow-up F1.)
    ///
    /// A title with an empty artist is routine — podcasts, live radio, a
    /// video in Safari — and under `&&` every one of those resolves to
    /// `nil`, blanking the panel header, the peek and the badge at once
    /// with nothing to show for it in the suite.
    @Test func aTitleWithNoArtistIsStillATrack() throws {
        let line = #"{"title":"The Rest Is History","artist":"","album":"","playing":true}"#
        let payload = try #require(MediaPayload.decode(line: line))

        let snapshot = try #require(payload.snapshot)
        #expect(snapshot.title == "The Rest Is History")
        #expect(snapshot.artist.isEmpty)
        #expect(snapshot.isPlaying)
    }

    /// The mirror case. Station feeds and some AirPlay sources publish an
    /// artist or station name with no title, and the predicate accepts them
    /// on purpose — the property's own comment now says so, having
    /// previously claimed the stricter "no title means no track".
    @Test func anArtistWithNoTitleIsStillATrack() throws {
        let line = #"{"title":"","artist":"BBC Radio 6 Music","album":"","playing":true}"#
        let payload = try #require(MediaPayload.decode(line: line))

        let snapshot = try #require(payload.snapshot)
        #expect(snapshot.title.isEmpty)
        #expect(snapshot.artist == "BBC Radio 6 Music")
    }

    /// Neither field is how "nothing is playing" actually arrives. It must
    /// become `nil` rather than an empty header — an album on its own is
    /// not a track anyone can read.
    @Test func aPayloadWithNeitherTitleNorArtistIsNoTrack() throws {
        let line = #"{"title":"","artist":"","album":"Believe","playing":true}"#
        let payload = try #require(MediaPayload.decode(line: line))

        #expect(payload.snapshot == nil)
    }

    /// Absent keys, not merely empty strings: the helper omits a field
    /// entirely when MediaRemote returns nothing for it, so this is the
    /// shape an idle machine really emits.
    @Test func aPayloadWithNoTextFieldsAtAllIsNoTrack() throws {
        let payload = try #require(MediaPayload.decode(line: #"{"playing":true}"#))

        #expect(payload.snapshot == nil)
    }

    /// The playing flag is carried straight through, never inferred from
    /// the text. The badge draws only while it is true, so a snapshot that
    /// invented `isPlaying` would put a cover beside the notch over paused
    /// music.
    @Test func theSnapshotCarriesThePlayingFlagUnchanged() throws {
        let paused = try #require(
            MediaPayload.decode(line: #"{"title":"T","artist":"A","playing":false}"#)
        )
        let playing = try #require(
            MediaPayload.decode(line: #"{"title":"T","artist":"A","playing":true}"#)
        )

        #expect(paused.snapshot?.isPlaying == false)
        #expect(playing.snapshot?.isPlaying == true)
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
