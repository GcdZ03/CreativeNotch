import Foundation
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// Snapshot in, decision out.
///
/// Every test drives `apply(_:now:)` directly. No IOKit, no clock, and no
/// charger being moved by hand — the whole module's behaviour is reachable
/// because the one stateful object takes a value and a time.
@MainActor
struct PowerControllerTests {

    /// Collects what the controller decided.
    private final class Recorder {
        var events: [PowerEvent] = []
        var snapshots: [PowerSnapshot] = []
        var estimates: [Int?] = []
    }

    private func snapshot(
        level: Int = 66,
        source: PowerSource = .battery,
        isCharging: Bool = false,
        estimateMinutes: Int? = 400,
        isLowPowerMode: Bool = false
    ) -> PowerSnapshot {
        PowerSnapshot(
            level: level, source: source, isCharging: isCharging,
            estimateMinutes: estimateMinutes, isLowPowerMode: isLowPowerMode
        )
    }

    private func controller() -> (PowerController, Recorder) {
        let recorder = Recorder()
        let controller = PowerController()
        controller.onEvent = { recorder.events.append($0) }
        controller.onSnapshot = { snapshot, estimate in
            recorder.snapshots.append(snapshot)
            recorder.estimates.append(estimate)
        }
        return (controller, recorder)
    }

    // MARK: - Transitions

    /// The first snapshot establishes a baseline. Launching the app on a
    /// plugged-in machine is not the charger being plugged in.
    @Test func theFirstSnapshotAnnouncesNothing() {
        let (controller, recorder) = controller()

        controller.apply(snapshot(source: .wall), now: 100)

        #expect(recorder.events.isEmpty)
    }

    @Test func pluggingInAnnouncesItself() {
        let (controller, recorder) = controller()
        controller.apply(snapshot(level: 66, source: .battery), now: 100)

        controller.apply(snapshot(level: 66, source: .wall), now: 200)

        #expect(recorder.events == [.pluggedIn(level: 66)])
    }

    @Test func unpluggingAnnouncesItself() {
        let (controller, recorder) = controller()
        controller.apply(snapshot(level: 66, source: .wall), now: 100)

        controller.apply(snapshot(level: 66, source: .battery), now: 200)

        #expect(recorder.events == [.unplugged(level: 66)])
    }

    /// The calibration probe measured the IOKit notification firing on
    /// estimate drift while the machine sat still — fourteen times in
    /// eighteen minutes, with the estimate wandering between 388 and 457
    /// minutes. None of those is a transition and none may speak.
    @Test func estimateDriftIsNotATransition() {
        let (controller, recorder) = controller()
        controller.apply(snapshot(estimateMinutes: 447), now: 100)

        controller.apply(snapshot(estimateMinutes: 457), now: 105)
        controller.apply(snapshot(estimateMinutes: 435), now: 110)
        controller.apply(snapshot(estimateMinutes: 388), now: 115)

        #expect(recorder.events.isEmpty)
    }

    /// Charging starting or stopping while the cable stays put is not a
    /// transition either — a machine reaching 100% stops charging without
    /// anything happening that a person needs to be told about.
    @Test func chargingStoppingOnWallPowerIsNotATransition() {
        let (controller, recorder) = controller()
        controller.apply(snapshot(source: .wall, isCharging: true), now: 100)

        controller.apply(snapshot(source: .wall, isCharging: false), now: 200)

        #expect(recorder.events.isEmpty)
    }

    // MARK: - Low Power Mode

    @Test func lowPowerModeTurningOnAnnouncesItself() {
        let (controller, recorder) = controller()
        controller.apply(snapshot(isLowPowerMode: false), now: 100)

        controller.apply(snapshot(isLowPowerMode: true), now: 200)

        #expect(recorder.events == [.lowPowerMode(enabled: true)])
    }

    @Test func lowPowerModeTurningOffAnnouncesItself() {
        let (controller, recorder) = controller()
        controller.apply(snapshot(isLowPowerMode: true), now: 100)

        controller.apply(snapshot(isLowPowerMode: false), now: 200)

        #expect(recorder.events == [.lowPowerMode(enabled: false)])
    }

    // MARK: - Low battery

    @Test func crossingAThresholdAnnouncesItself() {
        let (controller, recorder) = controller()
        controller.apply(snapshot(level: 25), now: 100)

        controller.apply(snapshot(level: 20), now: 200)

        #expect(recorder.events == [.lowBattery(threshold: 20, level: 20)])
    }

    /// macOS turns Low Power Mode on automatically at 20%, so both fire
    /// from one snapshot. The battery is the more urgent of the two, and
    /// the peek slot holds one thing.
    @Test func lowBatteryOutranksLowPowerModeFromTheSameSnapshot() {
        let (controller, recorder) = controller()
        controller.apply(snapshot(level: 25, isLowPowerMode: false), now: 100)

        controller.apply(snapshot(level: 20, isLowPowerMode: true), now: 200)

        #expect(recorder.events == [.lowBattery(threshold: 20, level: 20)])
    }

    /// A transition and a threshold in one snapshot: the cable moving is
    /// what the person just did, and the level is what it means.
    @Test func unpluggingBelowAThresholdReportsTheBattery() {
        let (controller, recorder) = controller()
        controller.apply(snapshot(level: 15, source: .wall), now: 100)

        controller.apply(snapshot(level: 15, source: .battery), now: 200)

        #expect(recorder.events == [.lowBattery(threshold: 20, level: 15)])
    }

    // MARK: - The activity gate

    /// The observer stays live in every state — suspending it would mean
    /// missing the plug-in that happened while the lid was shut — but a
    /// peek drawn at a locked screen is work nobody sees.
    @Test func noPeekWhileLocked() {
        let (controller, recorder) = controller()
        controller.apply(snapshot(source: .battery), now: 100)
        controller.setActivity(.locked)

        controller.apply(snapshot(source: .wall), now: 200)

        #expect(recorder.events.isEmpty)
    }

    @Test func noPeekWhileAsleep() {
        let (controller, recorder) = controller()
        controller.apply(snapshot(source: .battery), now: 100)
        controller.setActivity(.asleep)

        controller.apply(snapshot(source: .wall), now: 200)

        #expect(recorder.events.isEmpty)
    }

    /// Dropped, not deferred. A peek is an interruption timed to a moment,
    /// and replaying "unplugged" on unlock ten minutes later is a
    /// notification — which this app is not.
    @Test func transitionsDuringLockAreDroppedNotReplayed() {
        let (controller, recorder) = controller()
        controller.apply(snapshot(source: .battery), now: 100)
        controller.setActivity(.locked)
        controller.apply(snapshot(source: .wall), now: 200)

        controller.setActivity(.active)

        #expect(recorder.events.isEmpty)
    }

    /// But the state itself is not lost. The panel reads the snapshot, not
    /// the event, so unlocking shows current truth.
    @Test func thePanelStillSeesStateChangedDuringLock() {
        let (controller, recorder) = controller()
        controller.apply(snapshot(source: .battery), now: 100)
        controller.setActivity(.locked)

        controller.apply(snapshot(source: .wall), now: 200)

        #expect(recorder.snapshots.last?.source == .wall)
    }

    /// A threshold crossed behind a lock screen is still spent. It was
    /// genuinely crossed; the notch simply did not speak about it.
    /// Re-announcing it on unlock is the replay this module refuses.
    @Test func aThresholdCrossedWhileLockedIsStillSpent() {
        let (controller, recorder) = controller()
        controller.apply(snapshot(level: 25), now: 100)
        controller.setActivity(.locked)
        controller.apply(snapshot(level: 20), now: 200)

        controller.setActivity(.active)
        controller.apply(snapshot(level: 19), now: 300)

        #expect(recorder.events.isEmpty)
    }

    // MARK: - The estimate

    /// The gate's ordering constraint: the transition must be recorded
    /// before the snapshot that caused it is judged, or the first
    /// post-transition reading is measured against the old window and
    /// shown at the exact moment it is least trustworthy.
    @Test func theEstimateIsSuppressedImmediatelyAfterATransition() {
        let (controller, recorder) = controller()

        controller.apply(snapshot(source: .battery, estimateMinutes: 400), now: 100)
        controller.apply(snapshot(source: .battery, estimateMinutes: 402), now: 105)
        #expect(recorder.estimates.last == 402)

        controller.apply(snapshot(source: .wall, estimateMinutes: 402), now: 110)

        // `estimates` is `[Int?]`, so `.last` is `Int??` and comparing it
        // to `nil` asks whether the array is empty — which it is not, and
        // the assertion would pass for the wrong reason. The published
        // value has to be unwrapped one level before it can be checked.
        let published = recorder.estimates.last
        #expect(published != nil)
        #expect(published ?? 999 == nil)
    }

    /// The panel is told about every snapshot, trusted estimate or not.
    /// Silence about the estimate is not silence about the charge.
    @Test func everySnapshotReachesThePanel() {
        let (controller, recorder) = controller()

        controller.apply(snapshot(level: 66), now: 100)
        controller.apply(snapshot(level: 65), now: 200)

        #expect(recorder.snapshots.count == 2)
        #expect(recorder.snapshots.map(\.level) == [66, 65])
    }

    // MARK: - Lifecycle

    /// `start()` has to actually register, and `stop()` has to undo it.
    ///
    /// The `power?.start()` line in `AppDelegate` itself is covered by
    /// running the real app, as the clipboard, media and HUD start lines
    /// are — no test in this suite drives
    /// `applicationDidFinishLaunching`. This pins the half that can be
    /// pinned headlessly.
    @Test func startingBeginsObservingAndStoppingEnds() {
        let controller = PowerController()

        controller.start()
        #expect(controller.isObserving)

        controller.stop()
        #expect(controller.isObserving == false)
    }
}
