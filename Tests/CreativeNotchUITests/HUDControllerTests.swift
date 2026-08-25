import AppKit
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// The decision path, driven directly rather than through real hardware:
/// coalesce duplicates, attribute to a keypress, and only then peek.
@MainActor
struct HUDControllerTests {

    private func makeController() -> (HUDController, Box<[HUDKind]>) {
        let peeked = Box<[HUDKind]>([])
        let controller = HUDController(onPeek: { peeked.value.append($0) })
        return (controller, peeked)
    }

    final class Box<T> {
        var value: T
        init(_ value: T) { self.value = value }
    }

    @Test func aChangeFromElsewherePeeks() {
        let (controller, peeked) = makeController()
        controller.handle(.volume(0.4), at: 100)
        #expect(peeked.value == [.volume(0.4)])
    }

    @Test func aChangeRightAfterAKeypressStaysSilent() {
        let (controller, peeked) = makeController()
        controller.noteKeyPress(at: 100)
        controller.handle(.volume(0.4), at: 100.1)
        #expect(peeked.value.isEmpty)
    }

    @Test func aChangeLongAfterAKeypressPeeksAgain() {
        let (controller, peeked) = makeController()
        controller.noteKeyPress(at: 100)
        controller.handle(.volume(0.4), at: 105)
        #expect(peeked.value == [.volume(0.4)])
    }

    /// CoreAudio fires twice per change; only one peek should result.
    @Test func duplicateCallbacksProduceOnePeek() {
        let (controller, peeked) = makeController()
        controller.handle(.volume(0.4), at: 100)
        controller.handle(.volume(0.4), at: 100.001)
        #expect(peeked.value == [.volume(0.4)])
    }

    @Test func aGenuineStreamOfValuesAllPeek() {
        // Dragging a slider: distinct values, all real.
        let (controller, peeked) = makeController()
        controller.handle(.volume(0.40), at: 100)
        controller.handle(.volume(0.45), at: 100.01)
        controller.handle(.volume(0.50), at: 100.02)
        #expect(peeked.value.count == 3)
    }

    @Test func brightnessAndMuteBothPeek() {
        let (controller, peeked) = makeController()
        controller.handle(.brightness(0.6), at: 100)
        controller.handle(.mute(true), at: 101)
        #expect(peeked.value == [.brightness(0.6), .mute(true)])
    }

    /// A keypress suppresses one change, not everything after it.
    @Test func aKeypressDoesNotSuppressTheNextUnrelatedChange() {
        let (controller, peeked) = makeController()
        controller.noteKeyPress(at: 100)
        controller.handle(.volume(0.4), at: 100.1)     // suppressed
        controller.handle(.volume(0.5), at: 100.6)     // beyond the window
        #expect(peeked.value == [.volume(0.5)])
    }

    /// `stop()` must actually stop every source it owns, not just report
    /// success. `volume`, `brightness` and `keys` are `let`-declared at
    /// internal (not private) access precisely so this is provable rather
    /// than trusted — the same reasoning behind `VolumeObserver.registrationCount`
    /// and `BrightnessObserver.lastRegisteredCallback`.
    ///
    /// `start()` here touches real hardware, and each source's precondition
    /// is checked independently rather than all three being pinned down
    /// together, because the three fail for unrelated reasons:
    ///
    /// - `keys.isRunning` is safe everywhere: `NSEvent.addGlobalMonitorForEvents`
    ///   returns a non-nil token regardless of Accessibility — only event
    ///   *delivery* is gated, not installation — so it is asserted directly.
    /// - `volume.isRunning` is not safe on CI: GitHub Actions macOS runners
    ///   have a documented, intermittent bug (`actions/runner-images#13668`)
    ///   where the Null Audio Device fails to initialise, leaving no audio
    ///   device at all. `VolumeObserver.start()` then bails.
    /// - `brightness.isRunning` is not safe either: `DisplayServices`
    ///   notifications are tied to a real backlight, and whether a runner's
    ///   virtual display supports them is unverified.
    ///
    /// The `volume`/`brightness` preconditions are wrapped in
    /// `withKnownIssue(isIntermittent: true)` so an absent device is
    /// *attributed and visible* in the test output rather than either
    /// failing the whole test (the old behaviour) or being silently
    /// deleted (which would let `stop()` "pass" a source that never ran).
    /// Deleting the preconditions outright was rejected: they exist to
    /// stop this test passing for the wrong reason, a failure mode this
    /// project has hit twice already.
    ///
    /// Whether `stop()` actually did its job is still checked hard, but
    /// only for a source that is confirmed to have started — a source that
    /// never started can't prove anything about `stop()`, and asserting
    /// `isRunning == false` on it afterwards would be vacuously true. A
    /// genuine `stop()` regression on a host where a source *did* start is
    /// still caught loudly and unconditionally.
    @Test func stopStopsAllThreeOwnedSources() {
        let (controller, _) = makeController()
        controller.start()

        #expect(controller.keys.isRunning)

        let volumeStarted = controller.volume.isRunning
        withKnownIssue(
            "CI runners intermittently have no audio device (actions/runner-images#13668)",
            isIntermittent: true
        ) {
            #expect(volumeStarted)
        }

        let brightnessStarted = controller.brightness.isRunning
        withKnownIssue(
            "Whether a CI runner's virtual display supports DisplayServices brightness notifications is unverified",
            isIntermittent: true
        ) {
            #expect(brightnessStarted)
        }

        controller.stop()

        #expect(controller.keys.isRunning == false)

        if volumeStarted {
            #expect(controller.volume.isRunning == false)
        }
        if brightnessStarted {
            #expect(controller.brightness.isRunning == false)
        }
    }
}

