import Foundation
import Testing
@testable import CreativeNotchCore

/// Where playback is, from what MediaRemote reports (spec 2026-10-15,
/// follow-up).
///
/// MediaRemote does not tick the elapsed time. It republishes `elapsed`
/// with a fresh timestamp on each play, pause and seek — measured on
/// 2026-10-15 against Spotify, where elapsed + (now − timestamp) tracked
/// Spotify's own `player position` to within the gap between the reads.
struct PlaybackPositionTests {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func position(elapsed: Double = 30, duration: Double = 200) -> PlaybackPosition {
        PlaybackPosition(elapsed: elapsed, duration: duration, anchoredAt: t0)!
    }

    // MARK: - Advancing

    @Test func whilePlayingItAdvancesFromTheAnchor() {
        let p = position()
        #expect(p.elapsed(at: t0.addingTimeInterval(10), isPlaying: true) == 40)
    }

    /// Paused, the reported elapsed *is* the position, however long ago
    /// the reading was taken.
    @Test func whilePausedItStaysPut() {
        let p = position()
        #expect(p.elapsed(at: t0.addingTimeInterval(500), isPlaying: false) == 30)
    }

    @Test func itNeverRunsPastTheEnd() {
        let p = position(elapsed: 190)
        #expect(p.elapsed(at: t0.addingTimeInterval(60), isPlaying: true) == 200)
        #expect(p.fraction(at: t0.addingTimeInterval(60), isPlaying: true) == 1)
    }

    /// A clock that reads earlier than the anchor (the anchor came from
    /// another process) must not wind the position back below zero.
    @Test func itNeverRunsBeforeTheStart() {
        let p = position(elapsed: 2)
        #expect(p.elapsed(at: t0.addingTimeInterval(-10), isPlaying: true) == 0)
    }

    @Test func fractionAndRemainingAreConsistent() {
        let p = position(elapsed: 50, duration: 200)
        let at = t0.addingTimeInterval(50)
        #expect(p.fraction(at: at, isPlaying: true) == 0.5)
        #expect(p.remaining(at: at, isPlaying: true) == 100)
    }

    // MARK: - What counts as a position at all

    /// No duration means a live stream or a player that does not publish
    /// one. There is nothing to draw a bar against, so there is no position.
    @Test func aZeroOrNegativeDurationIsNoPosition() {
        #expect(PlaybackPosition(elapsed: 3, duration: 0, anchoredAt: t0) == nil)
        #expect(PlaybackPosition(elapsed: 3, duration: -1, anchoredAt: t0) == nil)
    }

    @Test func nonFiniteValuesAreNoPosition() {
        #expect(PlaybackPosition(elapsed: .nan, duration: 100, anchoredAt: t0) == nil)
        #expect(PlaybackPosition(elapsed: 3, duration: .infinity, anchoredAt: t0) == nil)
    }

    // MARK: - From the wire

    private let line = #"{"title":"T","artist":"A","playing":true,"elapsed":115.091,"duration":226.666,"elapsedAt":1800000000}"#

    @Test func thePayloadCarriesThePosition() throws {
        let p = try #require(MediaPayload.decode(line: line))
        let snap = try #require(p.snapshot)
        #expect(snap.position == PlaybackPosition(elapsed: 115.091, duration: 226.666, anchoredAt: t0))
    }

    /// Each field alone is not enough to place playback, and older helpers
    /// send none of them. Either way the track still decodes.
    @Test func aPartialPositionIsDroppedNotFatal() throws {
        for partial in [
            #"{"title":"T","playing":true,"elapsed":5}"#,
            #"{"title":"T","playing":true,"elapsed":5,"duration":100}"#,
            #"{"title":"T","playing":true,"duration":100,"elapsedAt":1800000000}"#,
            #"{"title":"T","playing":true}"#,
        ] {
            let snap = try #require(MediaPayload.decode(line: partial)?.snapshot)
            #expect(snap.title == "T")
            #expect(snap.position == nil)
        }
    }

    /// A wrongly typed field drops the position, never the line.
    @Test func aMistypedFieldDropsOnlyThePosition() throws {
        let bad = #"{"title":"T","playing":true,"elapsed":"soon","duration":100,"elapsedAt":1800000000}"#
        let snap = try #require(MediaPayload.decode(line: bad)?.snapshot)
        #expect(snap.title == "T")
        #expect(snap.position == nil)
    }
}
