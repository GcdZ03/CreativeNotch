import Foundation
import Testing
@testable import CreativeNotchCore

/// CoreAudio fires its volume listener **twice** for a single change — the
/// spike measured 8 callbacks for 4 changes, roughly a millisecond apart.
/// Passing both through would flicker the pill and restart the arbiter's
/// TTL twice per change.
struct HUDCoalescerTests {

    @Test func theFirstEventIsAlwaysAccepted() {
        var c = HUDCoalescer()
        let result = c.accept(.volume(0.3), at: 100)
        #expect(result)
    }

    @Test func anIdenticalEventAMillisecondLaterIsDropped() {
        var c = HUDCoalescer()
        _ = c.accept(.volume(0.3), at: 100)
        let result = c.accept(.volume(0.3), at: 100.001)
        #expect(result == false)
    }

    @Test func aDifferentLevelIsAcceptedEvenImmediately() {
        // Dragging a slider produces a genuine stream of distinct values.
        // Only exact repeats are duplicates.
        var c = HUDCoalescer()
        _ = c.accept(.volume(0.3), at: 100)
        let result = c.accept(.volume(0.35), at: 100.001)
        #expect(result)
    }

    @Test func theSameLevelAgainLaterIsAccepted() {
        // Nudge down then back up: the level repeats, but it is a real
        // second event, not a duplicate callback.
        var c = HUDCoalescer()
        _ = c.accept(.volume(0.3), at: 100)
        let result = c.accept(.volume(0.3), at: 100 + HUDCoalescer.minimumInterval + 0.001)
        #expect(result)
    }

    @Test func theBoundaryIsExclusive() {
        var c = HUDCoalescer()
        _ = c.accept(.volume(0.3), at: 100)
        // Exactly at the interval is still within the duplicate window.
        let result = c.accept(.volume(0.3), at: 100 + HUDCoalescer.minimumInterval)
        #expect(result == false)
    }

    @Test func differentKindsDoNotSuppressEachOther() {
        // Brightness and volume can legitimately change together.
        var c = HUDCoalescer()
        _ = c.accept(.volume(0.3), at: 100)
        let result = c.accept(.brightness(0.3), at: 100.001)
        #expect(result)
    }

    @Test func muteIsCoalescedLikeAnyOtherKind() {
        var c = HUDCoalescer()
        _ = c.accept(.mute(true), at: 100)
        let result1 = c.accept(.mute(true), at: 100.001)
        #expect(result1 == false)
        let result2 = c.accept(.mute(false), at: 100.002)
        #expect(result2)
    }

    @Test func theIntervalIsWhatTheSpecSays() {
        #expect(HUDCoalescer.minimumInterval == 0.05)
    }
}
