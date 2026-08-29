import Foundation
import Testing
@testable import CreativeNotchCore

/// The MediaRemote command constants.
///
/// These numbers are not documented by Apple and cannot be checked by the
/// compiler — a wrong one silently sends a different command, or none.
/// They are pinned here against what
/// `docs/research/2026-08-29-media-feasibility.md` actually verified,
/// including the later verification of `nextTrack` and `previousTrack`.
struct MediaCommandTests {

    @Test func theConstantsAreWhatWasVerifiedAgainstARealPlayer() {
        #expect(MediaCommand.togglePlayPause.rawValue == 2)
        #expect(MediaCommand.nextTrack.rawValue == 4)
        #expect(MediaCommand.previousTrack.rawValue == 5)
    }

    /// 3 is `stop` in the MediaRemote enum, and is deliberately absent —
    /// nothing in this module stops playback. This pins the gap so a
    /// future contributor does not "fix" the numbering by making the cases
    /// contiguous, which would silently repoint next and previous.
    @Test func theNumberingIsNotContiguous() {
        let values = MediaCommand.allCases.map(\.rawValue).sorted()
        #expect(values == [2, 4, 5])
        #expect(values.contains(3) == false)
    }
}
