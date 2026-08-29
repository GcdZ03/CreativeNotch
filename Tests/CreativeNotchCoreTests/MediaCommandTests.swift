import Foundation
import Testing
@testable import CreativeNotchCore

/// The MediaRemote command constants.
///
/// These numbers are not documented by Apple and cannot be checked by the
/// compiler — a wrong one silently sends a different command, or none.
/// They are pinned here against what
/// `docs/research/2026-08-29-media-feasibility.md` actually verified.
struct MediaCommandTests {

    @Test func theConstantsAreWhatTheSpikeVerified() {
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

    /// The spike sent togglePlayPause and confirmed it both ways against a
    /// real player. It did not send next or previous, because doing so
    /// moves the user's queue position. That distinction is recorded in
    /// the type so it cannot quietly be forgotten.
    @Test func onlyTogglePlayPauseIsProven() {
        #expect(MediaCommand.togglePlayPause.isVerified)
        #expect(MediaCommand.nextTrack.isVerified == false)
        #expect(MediaCommand.previousTrack.isVerified == false)
    }

    @Test func everyCaseIsDistinct() {
        let values = Set(MediaCommand.allCases.map(\.rawValue))
        #expect(values.count == MediaCommand.allCases.count)
    }
}
