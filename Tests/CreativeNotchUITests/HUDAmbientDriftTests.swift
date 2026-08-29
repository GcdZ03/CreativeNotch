import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// Replays the shape of a real ambient-light burst through the whole
/// controller path, because the bug it guards against was invisible at
/// every smaller scale: each individual event was legitimate, the
/// coalescer was right to pass it, and the significance gate was right to
/// accumulate it. Only the stream as a whole was wrong.
@MainActor
struct HUDAmbientDriftTests {

    /// Measured on an M-series MacBook, nothing touched: 2301 brightness
    /// events in bursts of ~58/sec, per-event steps of 0.00012 (median) to
    /// 0.00326 (worst), drifting 0.083 overall. The shipped pipeline
    /// showed 8 HUDs for it.
    @Test func aRealAmbientBurstProducesNoPeekAtAll() {
        var peeks: [HUDKind] = []
        let controller = HUDController { peeks.append($0) }

        // What start() does on a real launch: the backlight already has a
        // level, and the next ambient step must be measured against it.
        controller.noteBaseline(.brightness(0.59))

        var level = 0.59
        var t = 1000.0
        // 1300 events at 58/sec, stepping by ambient's *worst* measured
        // step — the most favourable case for the bug, not the average.
        for _ in 0..<1300 {
            level -= 0.00326
            t += 1.0 / 58.0
            controller.handle(.brightness(level), at: t)
        }

        #expect(peeks.isEmpty, "ambient drift must never reach the screen")
        // Prove the drift really was large enough to have fired before:
        // 1300 * 0.00326 is far beyond the 1/32 threshold.
        #expect(0.59 - level > HUDSignificanceGate.threshold * 10)
    }

    /// The other half of the contract: the module must still speak for the
    /// thing it exists to show.
    @Test func aControlCenterSizedChangeStillPeeks() {
        var peeks: [HUDKind] = []
        let controller = HUDController { peeks.append($0) }

        controller.handle(.brightness(0.5), at: 1000)
        controller.handle(.brightness(0.5 + 1.0 / 16.0), at: 1001)

        #expect(peeks.count == 2)
    }

    /// A drag is a stream of moderate steps, not one jump. It must still
    /// accumulate through the floor into a peek.
    @Test func aDeliberateDragStillPeeks() {
        var peeks: [HUDKind] = []
        let controller = HUDController { peeks.append($0) }

        controller.handle(.brightness(0.5), at: 1000)
        peeks.removeAll()

        var level = 0.5
        var t = 1000.0
        for _ in 0..<12 {
            level += 0.006
            t += 1.0 / 60.0
            controller.handle(.brightness(level), at: t)
        }

        #expect(!peeks.isEmpty, "a real drag must still show")
    }
}
