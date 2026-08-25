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
    /// `start()` here touches real hardware, and the key monitor needs
    /// Accessibility permission to actually install. The two `#expect`s
    /// right after `start()` pin that precondition down explicitly: on a
    /// host where one of the three never actually started, those fail
    /// loudly and explain why, rather than letting the after-`stop()`
    /// checks below pass vacuously for the wrong reason.
    @Test func stopStopsAllThreeOwnedSources() {
        let (controller, _) = makeController()
        controller.start()

        #expect(controller.volume.isRunning)
        #expect(controller.brightness.isRunning)
        #expect(controller.keys.isRunning)

        controller.stop()

        #expect(controller.volume.isRunning == false)
        #expect(controller.brightness.isRunning == false)
        #expect(controller.keys.isRunning == false)
    }
}

