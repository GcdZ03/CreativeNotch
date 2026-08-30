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
    }

    private func snapshot(
        level: Int = 66,
        source: PowerSource = .battery,
        isCharging: Bool = false,
        isLowPowerMode: Bool = false
    ) -> PowerSnapshot {
        PowerSnapshot(
            level: level, source: source, isCharging: isCharging,
            isLowPowerMode: isLowPowerMode
        )
    }

    private func controller() -> (PowerController, Recorder) {
        let recorder = Recorder()
        let controller = PowerController()
        controller.onEvent = { recorder.events.append($0) }
        controller.onSnapshot = { recorder.snapshots.append($0) }
        return (controller, recorder)
    }

    // MARK: - Transitions

    /// The first snapshot establishes a baseline. Launching the app on a
    /// plugged-in machine is not the charger being plugged in.
    @Test func theFirstSnapshotAnnouncesNothing() {
        let (controller, recorder) = controller()

        controller.apply(snapshot(source: .wall))

        #expect(recorder.events.isEmpty)
    }

    @Test func pluggingInAnnouncesItself() {
        let (controller, recorder) = controller()
        controller.apply(snapshot(level: 66, source: .battery))

        controller.apply(snapshot(level: 66, source: .wall))

        #expect(recorder.events == [.pluggedIn(level: 66)])
    }

    @Test func unpluggingAnnouncesItself() {
        let (controller, recorder) = controller()
        controller.apply(snapshot(level: 66, source: .wall))

        controller.apply(snapshot(level: 66, source: .battery))

        #expect(recorder.events == [.unplugged(level: 66)])
    }

    /// The calibration probe measured the IOKit notification firing on
    /// estimate drift while the machine sat still — 43 times in 39
    /// minutes. Now that the estimate is not part of the snapshot, those
    /// callbacks carry nothing and `PowerObserver.read()` drops them
    /// before they ever reach here. This pins the other half: even if one
    /// arrives, an unchanged level and source is not a transition.
    @Test func anUnchangedSnapshotIsNotATransition() {
        let (controller, recorder) = controller()
        controller.apply(snapshot(level: 66))

        controller.apply(snapshot(level: 66))
        controller.apply(snapshot(level: 66))

        #expect(recorder.events.isEmpty)
    }

    /// Charging starting or stopping while the cable stays put is not a
    /// transition either — a machine reaching 100% stops charging without
    /// anything happening that a person needs to be told about.
    @Test func chargingStoppingOnWallPowerIsNotATransition() {
        let (controller, recorder) = controller()
        controller.apply(snapshot(source: .wall, isCharging: true))

        controller.apply(snapshot(source: .wall, isCharging: false))

        #expect(recorder.events.isEmpty)
    }

    // MARK: - Low Power Mode

    @Test func lowPowerModeTurningOnAnnouncesItself() {
        let (controller, recorder) = controller()
        controller.apply(snapshot(isLowPowerMode: false))

        controller.apply(snapshot(isLowPowerMode: true))

        #expect(recorder.events == [.lowPowerMode(enabled: true)])
    }

    @Test func lowPowerModeTurningOffAnnouncesItself() {
        let (controller, recorder) = controller()
        controller.apply(snapshot(isLowPowerMode: true))

        controller.apply(snapshot(isLowPowerMode: false))

        #expect(recorder.events == [.lowPowerMode(enabled: false)])
    }

    // MARK: - Low battery

    @Test func crossingAThresholdAnnouncesItself() {
        let (controller, recorder) = controller()
        controller.apply(snapshot(level: 25))

        controller.apply(snapshot(level: 20))

        #expect(recorder.events == [.lowBattery(threshold: 20, level: 20)])
    }

    /// macOS turns Low Power Mode on automatically at 20%, so both fire
    /// from one snapshot. The battery is the more urgent of the two, and
    /// the peek slot holds one thing.
    @Test func lowBatteryOutranksLowPowerModeFromTheSameSnapshot() {
        let (controller, recorder) = controller()
        controller.apply(snapshot(level: 25, isLowPowerMode: false))

        controller.apply(snapshot(level: 20, isLowPowerMode: true))

        #expect(recorder.events == [.lowBattery(threshold: 20, level: 20)])
    }

    /// A transition and a threshold in one snapshot: the cable moving is
    /// what the person just did, and the level is what it means.
    @Test func unpluggingBelowAThresholdReportsTheBattery() {
        let (controller, recorder) = controller()
        controller.apply(snapshot(level: 15, source: .wall))

        controller.apply(snapshot(level: 15, source: .battery))

        #expect(recorder.events == [.lowBattery(threshold: 20, level: 15)])
    }

    // MARK: - The activity gate

    /// The observer stays live in every state — suspending it would mean
    /// missing the plug-in that happened while the lid was shut — but a
    /// peek drawn at a locked screen is work nobody sees.
    @Test func noPeekWhileLocked() {
        let (controller, recorder) = controller()
        controller.apply(snapshot(source: .battery))
        controller.setActivity(.locked)

        controller.apply(snapshot(source: .wall))

        #expect(recorder.events.isEmpty)
    }

    @Test func noPeekWhileAsleep() {
        let (controller, recorder) = controller()
        controller.apply(snapshot(source: .battery))
        controller.setActivity(.asleep)

        controller.apply(snapshot(source: .wall))

        #expect(recorder.events.isEmpty)
    }

    /// Dropped, not deferred. A peek is an interruption timed to a moment,
    /// and replaying "unplugged" on unlock ten minutes later is a
    /// notification — which this app is not.
    @Test func transitionsDuringLockAreDroppedNotReplayed() {
        let (controller, recorder) = controller()
        controller.apply(snapshot(source: .battery))
        controller.setActivity(.locked)
        controller.apply(snapshot(source: .wall))

        controller.setActivity(.active)

        #expect(recorder.events.isEmpty)
    }

    /// But the state itself is not lost. The panel reads the snapshot, not
    /// the event, so unlocking shows current truth.
    @Test func thePanelStillSeesStateChangedDuringLock() {
        let (controller, recorder) = controller()
        controller.apply(snapshot(source: .battery))
        controller.setActivity(.locked)

        controller.apply(snapshot(source: .wall))

        #expect(recorder.snapshots.last?.source == .wall)
    }

    /// A threshold crossed behind a lock screen is still spent. It was
    /// genuinely crossed; the notch simply did not speak about it.
    /// Re-announcing it on unlock is the replay this module refuses.
    @Test func aThresholdCrossedWhileLockedIsStillSpent() {
        let (controller, recorder) = controller()
        controller.apply(snapshot(level: 25))
        controller.setActivity(.locked)
        controller.apply(snapshot(level: 20))

        controller.setActivity(.active)
        controller.apply(snapshot(level: 19))

        #expect(recorder.events.isEmpty)
    }

    // MARK: - The panel

    /// The panel is told about every snapshot that gets this far.
    @Test func everySnapshotReachesThePanel() {
        let (controller, recorder) = controller()

        controller.apply(snapshot(level: 66))
        controller.apply(snapshot(level: 65))

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
