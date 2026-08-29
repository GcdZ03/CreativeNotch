import Foundation
import Testing
@testable import CreativeNotchCore

/// The ambient light sensor does not merely jitter — it *ramps*. Measured
/// on an M-series MacBook with nothing touched: 2301 brightness events,
/// arriving in bursts of ~58/sec, moving the backlight 0.023 in a quarter
/// second and 0.046 in a second. Both exceed `HUDSignificanceGate`'s
/// 1/32 threshold, so the accumulate-until-significant rule fired **8
/// spurious HUDs** with no user input at all.
///
/// A rate gate cannot separate the two: an ambient ramp and a Control
/// Center slider drag move at the same speed. What separates them is the
/// size of each individual step. Measured across 2063 ambient steps:
///
///   median 0.00012 · p99 0.00088 · p99.9 0.00193 · **worst 0.00326**
///
/// against 0.0625 for a keypress or a Control Center click — 19× the worst
/// ambient step. The floor sits between the two, so ambient never
/// accumulates while deliberate changes always do.
struct HUDNoiseFloorTests {

    /// The number this whole fix rests on. If someone lowers it under the
    /// measured ambient worst case, the spurious HUDs come straight back.
    @Test func theFloorSitsAboveTheMeasuredAmbientWorstCase() {
        #expect(HUDSignificanceGate.noiseFloor > 0.00326)
        // ...and below a keypress step, or deliberate changes get eaten too.
        #expect(HUDSignificanceGate.noiseFloor < 0.0625)
    }

    /// The exact failure the user reported: drift that accumulates past
    /// the threshold and pops a HUD nobody asked for.
    @Test func ambientSizedStepsNeverAccumulateIntoAPeek() {
        var gate = HUDSignificanceGate()
        var level = 0.5
        gate.commitObserved(.brightness(level))
        gate.commitShown(.brightness(level))

        // 500 steps of 0.0001 — well inside ambient's measured range, and
        // 0.05 in total, which is comfortably past the 1/32 threshold.
        for _ in 0..<500 {
            level += 0.0001
            let kind = HUDKind.brightness(level)
            let above = gate.isAboveNoiseFloor(kind)
            gate.commitObserved(kind)
            #expect(!above, "an ambient-sized step must never reach the significance gate")
        }
        #expect(level - 0.5 > HUDSignificanceGate.threshold, "the drift really did exceed the threshold")
    }

    /// The floor must not eat the thing the module exists to show. A
    /// Control Center drag moves in steps far larger than ambient.
    @Test func aDeliberateDragStillAccumulatesToAPeek() {
        var gate = HUDSignificanceGate()
        gate.commitObserved(.brightness(0.5))
        gate.commitShown(.brightness(0.5))

        var level = 0.5
        var peeked = false
        for _ in 0..<10 {
            level += 0.006          // a slow-but-real drag step
            let kind = HUDKind.brightness(level)
            guard gate.isAboveNoiseFloor(kind) else { gate.commitObserved(kind); continue }
            gate.commitObserved(kind)
            if gate.isSignificant(kind) { gate.commitShown(kind); peeked = true }
        }
        #expect(peeked, "steps above the floor must still accumulate to the threshold")
    }

    @Test func aKeypressSizedJumpIsAlwaysAboveTheFloor() {
        var gate = HUDSignificanceGate()
        gate.commitObserved(.brightness(0.5))
        #expect(gate.isAboveNoiseFloor(.brightness(0.5 + 1.0 / 16.0)))
    }

    /// The first event of a channel establishes the baseline and is never
    /// shown.
    ///
    /// This used to return `true`, reasoning that suppressing it would
    /// make the first change after launch invisible. Watching the real app
    /// showed the opposite: `start()` primes the baseline by reading the
    /// current level, but that read can come back `nil` — DisplayServices
    /// is not always ready the instant the observer starts — and when it
    /// does, the next ambient tick becomes "the first thing ever seen",
    /// passes every filter, and pops a HUD half a second after launch.
    /// Observed on one launch and not the next, which is exactly what
    /// "randomly appears" looks like from outside.
    ///
    /// Establishing the baseline from the event itself makes the race
    /// harmless. The cost is one swallowed change if someone alters volume
    /// in the instant after launch, which is far cheaper than a pop nobody
    /// asked for.
    @Test func theFirstEventOfAChannelEstablishesTheBaselineSilently() {
        var gate = HUDSignificanceGate()
        #expect(!gate.isAboveNoiseFloor(.brightness(0.5)))
        #expect(!gate.isAboveNoiseFloor(.volume(0.5)))

        // ...and having established it, a real change still shows.
        gate.commitObserved(.brightness(0.5))
        #expect(gate.isAboveNoiseFloor(.brightness(0.5 + 1.0 / 16.0)))
    }

    /// Mute has no magnitude, so it cannot have a noise floor — but it
    /// must not therefore be unfiltered. Every mute callback used to reach
    /// the screen, because `isSignificant` returned `true` unconditionally
    /// and `commitShown` recorded nothing. A driver re-notifying the same
    /// state — on a route change, a device switch, a wake — popped a
    /// speaker HUD each time, with nobody having touched anything.
    @Test func aRepeatedMuteStateIsNotShownTwice() {
        var gate = HUDSignificanceGate()
        #expect(gate.isSignificant(.mute(true)))
        gate.commitShown(.mute(true))

        #expect(!gate.isSignificant(.mute(true)), "the same mute state must not show again")
        #expect(gate.isSignificant(.mute(false)), "an actual toggle must still show")
    }

    /// Mute and the level channels must not interfere.
    @Test func muteIsTrackedSeparatelyFromTheLevels() {
        var gate = HUDSignificanceGate()
        gate.commitShown(.mute(true))
        gate.commitObserved(.volume(0.5))
        gate.commitShown(.volume(0.5))
        #expect(!gate.isSignificant(.mute(true)))
        #expect(gate.isSignificant(.volume(0.9)))
    }

    /// Mute carries no magnitude, so a noise floor is meaningless for it.
    @Test func muteIsNeverFilteredAsNoise() {
        var gate = HUDSignificanceGate()
        gate.commitObserved(.mute(true))
        // No magnitude, so the *floor* cannot apply — repetition is
        // handled by the significance gate instead, above.
        #expect(gate.isAboveNoiseFloor(.mute(true)))
        #expect(gate.isAboveNoiseFloor(.mute(false)))
    }

    /// Volume and brightness must not share a floor baseline, or a
    /// brightness ramp would mask a real volume change.
    @Test func channelsAreTrackedIndependently() {
        var gate = HUDSignificanceGate()
        gate.commitObserved(.brightness(0.5))
        gate.commitObserved(.volume(0.9))
        #expect(!gate.isAboveNoiseFloor(.brightness(0.5005)))
        #expect(gate.isAboveNoiseFloor(.volume(0.5)))
    }
}
