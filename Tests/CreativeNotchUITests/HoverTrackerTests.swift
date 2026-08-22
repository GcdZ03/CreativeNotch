import AppKit
import Testing
@testable import CreativeNotchUI

/// Covers the dwell timing state machine and the coordinate-space seam
/// `HoverTracker` sits on: `NSTrackingArea` rects are interpreted in the
/// owning view's own space, and `updateTrackingRect(_:)` receives a rect
/// from `NotchShape.visibleRect`, which is documented as bottom-left
/// origin, y-up — matching an *unflipped* `NSView`. If `HoverTracker` were
/// ever made flipped, this would silently reproduce the same y-axis
/// inversion bug fixed in `HitTestingHostingView`.
@MainActor
struct HoverTrackerTests {

    private func enterEvent() -> NSEvent {
        NSEvent.enterExitEvent(
            with: .mouseEntered,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            trackingNumber: 0,
            userData: nil
        )!
    }

    private func exitEvent() -> NSEvent {
        NSEvent.enterExitEvent(
            with: .mouseExited,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            trackingNumber: 0,
            userData: nil
        )!
    }

    // MARK: - Coordinate space

    /// `HoverTracker` must stay unflipped so a rect from
    /// `NotchShape.visibleRect` (bottom-left origin, y-up) lands in the
    /// tracking area unmodified — no flip transform required.
    @Test func staysUnflippedToMatchVisibleRectsCoordinateSpace() {
        let tracker = HoverTracker(frame: CGRect(x: 0, y: 0, width: 620, height: 260))
        #expect(tracker.isFlipped == false)
    }

    /// The reviewer's real numbers from the hit-testing fix: a peek-sized
    /// band top-aligned inside a 620x260 panel, in panel-local bottom-left
    /// coordinates. The tracking area's rect must equal this exactly — no
    /// mirroring around the panel height.
    @Test func updateTrackingRectPlacesTheAreaInUnflippedCoordinates() {
        let tracker = HoverTracker(frame: CGRect(x: 0, y: 0, width: 620, height: 260))
        let rect = CGRect(x: 230, y: 223, width: 160, height: 37)

        tracker.updateTrackingRect(rect)

        #expect(tracker.trackingAreas.count == 1)
        #expect(tracker.trackingAreas.first?.rect == rect)
    }

    @Test func emptyTrackingRectAddsNoTrackingArea() {
        let tracker = HoverTracker(frame: CGRect(x: 0, y: 0, width: 620, height: 260))
        tracker.updateTrackingRect(.zero)
        #expect(tracker.trackingAreas.isEmpty)
    }

    @Test func updatingTheTrackingRectReplacesThePreviousArea() {
        let tracker = HoverTracker(frame: CGRect(x: 0, y: 0, width: 620, height: 260))
        tracker.updateTrackingRect(CGRect(x: 0, y: 0, width: 100, height: 100))
        tracker.updateTrackingRect(CGRect(x: 10, y: 10, width: 50, height: 50))

        #expect(tracker.trackingAreas.count == 1)
        #expect(tracker.trackingAreas.first?.rect == CGRect(x: 10, y: 10, width: 50, height: 50))
    }

    // MARK: - Hit testing

    /// Sits above the hosting view so its tracking area covers the panel;
    /// must never intercept a click meant for SwiftUI content beneath it.
    @Test func hitTestAlwaysReturnsNilSoClicksPassThrough() {
        let tracker = HoverTracker(frame: CGRect(x: 0, y: 0, width: 620, height: 260))
        #expect(tracker.hitTest(NSPoint(x: 300, y: 130)) == nil)
    }

    // MARK: - Dwell timing

    /// `onEnter` is what cancels a pending dismissal, so it has to fire the
    /// moment the cursor arrives -- not 300ms later with the dwell.
    @Test func enteringFiresOnEnterImmediately() {
        let tracker = HoverTracker(frame: .zero)
        let entered = Flag()
        tracker.onEnter = { entered.set() }

        tracker.mouseEntered(with: enterEvent())

        // No sleep: `onDwell` waits, `onEnter` must not.
        #expect(entered.value)
    }

    @Test func enteringDoesNotFireTheDwellYet() {
        let tracker = HoverTracker(frame: .zero)
        let dwelled = Flag()
        tracker.onDwell = { dwelled.set() }

        tracker.mouseEntered(with: enterEvent())

        #expect(!dwelled.value)
    }

    @Test func dwellFiresAfterTheDelayElapses() async {
        let tracker = HoverTracker(frame: .zero)
        let fired = Flag()
        tracker.onDwell = { fired.set() }

        tracker.mouseEntered(with: enterEvent())
        await tracker.dwellTask?.value

        #expect(fired.value)
    }

    @Test func exitingBeforeTheDwellElapsesCancelsIt() async {
        let tracker = HoverTracker(frame: .zero)
        let fired = Flag()
        tracker.onDwell = { fired.set() }

        tracker.mouseEntered(with: enterEvent())
        tracker.mouseExited(with: exitEvent())
        await tracker.dwellTask?.value

        #expect(!fired.value)
    }

    @Test func mouseExitedAlwaysCallsOnExit() {
        let tracker = HoverTracker(frame: .zero)
        let exited = Flag()
        tracker.onExit = { exited.set() }

        tracker.mouseExited(with: exitEvent())

        #expect(exited.value)
    }

    /// Re-entering before the previous dwell fires must restart the clock,
    /// not stack a second timer.
    @Test func reenteringRestartsTheDwellRatherThanStacking() async {
        let tracker = HoverTracker(frame: .zero)
        let dwellCount = Counter()
        tracker.onDwell = { dwellCount.increment() }

        // No sleep between the two entries. Sleeping "less than the dwell"
        // is itself a race: on a slow runner the wait overshoots, the first
        // dwell fires, and the count is 2. Holding the first task and
        // awaiting it proves it was cancelled instead.
        tracker.mouseEntered(with: enterEvent())
        let firstDwell = tracker.dwellTask
        tracker.mouseEntered(with: enterEvent())

        await firstDwell?.value          // cancelled — returns at once
        await tracker.dwellTask?.value   // the one that should fire

        #expect(dwellCount.value == 1)
    }
}

/// A tiny `@MainActor` box so dwell-callback closures can mutate state
/// without capturing a `var` across the concurrency boundary.
@MainActor
private final class Flag {
    private(set) var value = false
    func set() { value = true }
}

@MainActor
private final class Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}
