import Foundation
import Testing
@testable import CreativeNotchCore

/// Collapses the notification burst.
///
/// The spike measured about six emissions for a single press of play.
/// Passing all of them through would rebuild the header and restart peek
/// arbitration six times for one user action. Same problem `HUDCoalescer`
/// solves for CoreAudio.
///
/// Deduping on `TrackSnapshot` equality is what makes this cheap — artwork
/// lives in the cache, not in the snapshot, so equality never compares
/// image bytes.
struct MediaCoalescerTests {

    private func snap(_ title: String, playing: Bool = true) -> TrackSnapshot {
        TrackSnapshot(title: title, artist: "A", isPlaying: playing)
    }

    @Test func theFirstSnapshotIsAlwaysAccepted() {
        var c = MediaCoalescer()
        let result = c.accept(snap("one"))
        #expect(result)
    }

    @Test func anIdenticalRepeatIsDropped() {
        var c = MediaCoalescer()
        _ = c.accept(snap("one"))
        let result = c.accept(snap("one"))
        #expect(result == false)
    }

    /// The measured burst: six identical emissions, one visible update.
    @Test func aBurstOfIdenticalEmissionsCollapsesToOne() {
        var c = MediaCoalescer()
        let accepted = (0..<6).filter { _ in c.accept(snap("same")) }.count
        #expect(accepted == 1)
    }

    @Test func aChangedTrackIsAccepted() {
        var c = MediaCoalescer()
        _ = c.accept(snap("one"))
        let result = c.accept(snap("two"))
        #expect(result)
    }

    /// Play/pause on the same track is a real change the user is waiting
    /// to see — it must not be swallowed as a duplicate.
    @Test func aPlayStateChangeOnTheSameTrackIsAccepted() {
        var c = MediaCoalescer()
        _ = c.accept(snap("one", playing: true))
        let result = c.accept(snap("one", playing: false))
        #expect(result)
    }

    /// Media stopping entirely is a transition, and repeats of it are not.
    @Test func nilIsAcceptedOnceThenDeduped() {
        var c = MediaCoalescer()
        _ = c.accept(snap("one"))
        let result1 = c.accept(nil)
        #expect(result1)
        let result2 = c.accept(nil)
        #expect(result2 == false)
    }
}
