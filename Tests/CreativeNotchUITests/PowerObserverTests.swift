import Foundation
import IOKit.ps
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// The IOKit edge.
///
/// The conversion is tested against dictionaries shaped like the ones
/// `docs/research/2026-08-30-battery-estimate-noise.md` recorded from a
/// real machine. The notification registration is tested by counting what
/// `start` and `stop` leave behind — moving a real charger by hand is not
/// something a test suite can do.
@MainActor
struct PowerObserverTests {

    private func description(
        current: Int = 66,
        max: Int = 100,
        state: String = kIOPSBatteryPowerValue,
        charging: Bool = false,
        timeToEmpty: Int = 435,
        type: String = kIOPSInternalBatteryType
    ) -> [String: Any] {
        [
            kIOPSTypeKey: type,
            kIOPSCurrentCapacityKey: current,
            kIOPSMaxCapacityKey: max,
            kIOPSPowerSourceStateKey: state,
            kIOPSIsChargingKey: charging,
            kIOPSTimeToEmptyKey: timeToEmpty,
        ]
    }

    // MARK: - The sentinel

    /// IOKit documents -1 as "Still Calculating the Time" (`IOPSKeys.h`).
    /// It is converted to an absence exactly here, so nothing above this
    /// line can render it as a duration.
    @Test func theStillCalculatingSentinelBecomesNil() {
        let snapshot = PowerObserver.snapshot(
            from: description(timeToEmpty: -1), isLowPowerMode: false
        )

        #expect(snapshot != nil)
        #expect(snapshot?.estimateMinutes == nil)
    }

    @Test func anOrdinaryEstimateSurvives() {
        let snapshot = PowerObserver.snapshot(
            from: description(timeToEmpty: 435), isLowPowerMode: false
        )

        #expect(snapshot?.estimateMinutes == 435)
    }

    /// Any negative value, not only -1. A sentinel that changes shape in
    /// a future macOS must not become a negative duration on screen.
    @Test func anyNegativeEstimateIsAbsent() {
        let snapshot = PowerObserver.snapshot(
            from: description(timeToEmpty: -999), isLowPowerMode: false
        )

        #expect(snapshot?.estimateMinutes == nil)
    }

    /// A missing key is an absent estimate, not a crash and not a zero.
    @Test func aMissingEstimateKeyIsAbsent() {
        var d = description()
        d.removeValue(forKey: kIOPSTimeToEmptyKey)

        #expect(PowerObserver.snapshot(from: d, isLowPowerMode: false)?
            .estimateMinutes == nil)
    }

    /// On wall power IOKit publishes time-to-full instead of
    /// time-to-empty. Reading the wrong key leaves the panel permanently
    /// "Estimating…" while charging — the module half-working in the way
    /// least likely to be noticed.
    @Test func chargingReadsTimeToFullRatherThanTimeToEmpty() {
        var d = description(state: kIOPSACPowerValue, charging: true)
        d[kIOPSTimeToFullChargeKey] = 42

        #expect(PowerObserver.snapshot(from: d, isLowPowerMode: false)?
            .estimateMinutes == 42)
    }

    /// Plugged in but not charging: IOKit reports `Time to Full Charge`
    /// as **0**, meaning "not applicable", not "zero minutes away".
    ///
    /// Measured on a real machine — the probe caught exactly this while
    /// the charger was attached at 55% and nothing was charging:
    /// `state=AC Power charging=false toEmpty=0 toFull=0`. Filtering only
    /// *negative* values lets that 0 through, and the panel reads
    /// "Until full: 0 min".
    ///
    /// Zero is a legitimate time-to-empty — a battery about to die — so
    /// the fix cannot simply reject zero everywhere. It is the *charging*
    /// key that is meaningless when nothing is charging.
    @Test func pluggedInButNotChargingHasNoEstimate() {
        var d = description(state: kIOPSACPowerValue, charging: false)
        d[kIOPSTimeToFullChargeKey] = 0

        let snapshot = PowerObserver.snapshot(from: d, isLowPowerMode: false)

        #expect(snapshot?.source == .wall)
        #expect(snapshot?.estimateMinutes == nil)
    }

    /// And not even a positive one. If nothing is charging there is no
    /// time-to-full to report, whatever number is left in the dictionary.
    @Test func aStaleTimeToFullIsIgnoredWhenNotCharging() {
        var d = description(state: kIOPSACPowerValue, charging: false)
        d[kIOPSTimeToFullChargeKey] = 42

        #expect(PowerObserver.snapshot(from: d, isLowPowerMode: false)?
            .estimateMinutes == nil)
    }

    /// Zero minutes *to empty* is a real reading and must survive — it is
    /// the most urgent one the module can carry.
    @Test func zeroMinutesToEmptyIsARealReading() {
        let snapshot = PowerObserver.snapshot(
            from: description(timeToEmpty: 0), isLowPowerMode: false
        )

        #expect(snapshot?.estimateMinutes == 0)
    }

    /// "Full and finished" and "plugged in but not taking charge" are
    /// different states that both have `Is Charging = 0`. Without reading
    /// `Is Charged`, a machine sitting at 100% is reported as "Not
    /// charging", which reads as a fault rather than as success.
    @Test func chargedIsReadSeparatelyFromCharging() {
        var full = description(state: kIOPSACPowerValue, charging: false)
        full[kIOPSIsChargedKey] = true

        var stalled = description(state: kIOPSACPowerValue, charging: false)
        stalled[kIOPSIsChargedKey] = false

        #expect(PowerObserver.snapshot(from: full, isLowPowerMode: false)?.isCharged == true)
        #expect(PowerObserver.snapshot(from: stalled, isLowPowerMode: false)?.isCharged == false)
    }

    // MARK: - Source

    @Test func wallPowerIsRecognised() {
        let snapshot = PowerObserver.snapshot(
            from: description(state: kIOPSACPowerValue), isLowPowerMode: false
        )

        #expect(snapshot?.source == .wall)
        #expect(snapshot?.isPluggedIn == true)
    }

    @Test func batteryPowerIsRecognised() {
        let snapshot = PowerObserver.snapshot(
            from: description(state: kIOPSBatteryPowerValue), isLowPowerMode: false
        )

        #expect(snapshot?.source == .battery)
    }

    /// An unrecognised state string is battery, not wall. Guessing wrong
    /// in the other direction tells someone running on reserve that they
    /// are plugged in.
    @Test func anUnknownSourceIsTreatedAsBattery() {
        let snapshot = PowerObserver.snapshot(
            from: description(state: "Something New"), isLowPowerMode: false
        )

        #expect(snapshot?.source == .battery)
    }

    // MARK: - Level

    /// The probe observed `pct=66/100`, but a maximum of 100 is not
    /// guaranteed — the percentage is computed, not read.
    @Test func theLevelIsAPercentageOfMaxCapacity() {
        let snapshot = PowerObserver.snapshot(
            from: description(current: 30, max: 60), isLowPowerMode: false
        )

        #expect(snapshot?.level == 50)
    }

    /// A zero maximum is a division by zero waiting to happen. IOKit
    /// should never report it; this module should never produce nonsense
    /// if it does.
    @Test func aZeroMaximumDoesNotProduceASnapshot() {
        #expect(PowerObserver.snapshot(
            from: description(current: 30, max: 0), isLowPowerMode: false
        ) == nil)
    }

    // MARK: - Which power source

    /// A UPS is not an internal battery, and this app does not speak for
    /// one. Mapping it onto the internal battery would report a desktop's
    /// backup as the machine's own charge.
    @Test func onlyTheInternalBatteryIsRead() {
        #expect(PowerObserver.snapshot(
            from: description(type: kIOPSUPSType), isLowPowerMode: false
        ) == nil)
    }

    // MARK: - Low Power Mode

    /// LPM arrives on a different notification and is passed in rather
    /// than read from the dictionary, because IOKit's power source
    /// description does not carry it.
    @Test func lowPowerModeIsCarriedThrough() {
        #expect(PowerObserver.snapshot(
            from: description(), isLowPowerMode: true
        )?.isLowPowerMode == true)
    }

    // MARK: - Lifecycle

    /// `VolumeObserver`, `BrightnessObserver` and `MediaKeyMonitor` each
    /// shipped a `stop()` that forgot one of the things `start()`
    /// registered, and each was caught by a count exactly like this one.
    ///
    /// This assertion is necessary and *not* sufficient, which the tests
    /// below cover: clearing the field and actually deregistering are two
    /// different things, and a count cannot tell them apart. Both of the
    /// mutations that matter here survived this test alone.
    @Test func stopUndoesEverythingStartRegistered() {
        let observer = PowerObserver()
        observer.start()

        #expect(observer.registrationCount == 2)

        observer.stop()
        #expect(observer.registrationCount == 0)
    }

    /// The run loop, not the field, is asked whether the source is gone.
    ///
    /// `stop()` nils its own field either way; only `CFRunLoopContainsSource`
    /// distinguishes a real removal from a forgotten one. This is also
    /// where the mode matters — a source removed from a different mode
    /// than it was added to stays installed and the call silently
    /// succeeds.
    @Test func stoppingActuallyRemovesTheRunLoopSource() {
        let observer = PowerObserver()
        observer.start()
        let source = observer.runLoopSource

        #expect(source != nil)
        #expect(CFRunLoopContainsSource(CFRunLoopGetMain(), source, .defaultMode))

        observer.stop()

        #expect(CFRunLoopContainsSource(CFRunLoopGetMain(), source, .defaultMode) == false)
    }

    /// The notification observer, proved by delivery rather than by a
    /// field being nil. A `stop()` that clears the token without calling
    /// `removeObserver` keeps receiving notifications forever, and the
    /// count says everything is fine.
    @Test func stoppingActuallyRemovesTheNotificationObserver() {
        let observer = PowerObserver()
        observer.start()
        observer.stop()
        let before = observer.readCount

        NotificationCenter.default.post(
            name: .NSProcessInfoPowerStateDidChange, object: nil
        )

        #expect(observer.readCount == before)
    }

    /// Starting twice must not stack. It is a wiring mistake, not a
    /// reason to receive every event twice — and a second registration
    /// over the first leaves `registrationCount` at 2, looking correct.
    @Test func startingTwiceDeliversEachNotificationOnce() {
        let observer = PowerObserver()
        observer.start()
        observer.start()
        let before = observer.readCount

        NotificationCenter.default.post(
            name: .NSProcessInfoPowerStateDidChange, object: nil
        )

        #expect(observer.readCount == before + 1)

        observer.stop()
    }

    @Test func startingTwiceLeavesOneSourceInTheRunLoop() {
        let observer = PowerObserver()
        observer.start()
        let first = observer.runLoopSource
        observer.start()

        // The first source must have been removed, not merely dropped.
        #expect(CFRunLoopContainsSource(CFRunLoopGetMain(), first, .defaultMode) == false)

        observer.stop()
    }

    @Test func stoppingWithoutStartingIsHarmless() {
        let observer = PowerObserver()
        observer.stop()

        #expect(observer.registrationCount == 0)
    }

    /// A callback carrying nothing new must not republish. The probe
    /// measured the IOKit notification firing repeatedly on a machine
    /// sitting still, and every one of those reaches `read()`.
    @Test func anUnchangedReadDoesNotRepublish() {
        final class Count { var value = 0 }
        let count = Count()
        let observer = PowerObserver()
        observer.onChange = { _ in count.value += 1 }

        observer.read()
        let afterFirst = count.value

        observer.read()

        #expect(count.value == afterFirst)
    }
}
