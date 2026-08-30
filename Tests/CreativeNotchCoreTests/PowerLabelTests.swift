import Foundation
import Testing
@testable import CreativeNotchCore

/// Every string this module shows, decided in one place.
struct PowerLabelTests {

    // MARK: - Time remaining

    /// The gate returning nil is the ordinary case, not an error. The row
    /// keeps its place rather than vanishing — a panel that changes height
    /// every time the charger moves is worse than the noisy number the
    /// gate exists to suppress.
    @Test func anUntrustedEstimateReadsAsEstimating() {
        #expect(PowerLabel.timeRemaining(nil) == "Estimating…")
    }

    @Test func hoursAndMinutesAreFormattedAsAClock() {
        #expect(PowerLabel.timeRemaining(135) == "2:15")
        #expect(PowerLabel.timeRemaining(65) == "1:05")
    }

    /// Exactly an hour is the boundary between the two formats, and the
    /// one most likely to be got wrong by a `>` that should be a `>=`.
    @Test func exactlyAnHourIsAClock() {
        #expect(PowerLabel.timeRemaining(60) == "1:00")
        #expect(PowerLabel.timeRemaining(59) == "59 min")
    }

    /// Under an hour is minutes, not "0:45" — the leading zero reads as a
    /// clock that has stopped.
    @Test func underAnHourIsMinutes() {
        #expect(PowerLabel.timeRemaining(45) == "45 min")
        #expect(PowerLabel.timeRemaining(1) == "1 min")
    }

    /// Zero is a real reading, not a missing one, and must not fall
    /// through to the nil case.
    @Test func zeroIsNotTreatedAsUnknown() {
        #expect(PowerLabel.timeRemaining(0) == "0 min")
    }

    /// The minutes are zero-padded. "2:5" is not a duration.
    @Test func minutesArePaddedAgainstTheHour() {
        #expect(PowerLabel.timeRemaining(125) == "2:05")
    }

    // MARK: - State

    @Test func stateNamesWhatIsActuallyHappening() {
        #expect(PowerLabel.state(source: .wall, isCharging: true) == "Charging")
        #expect(PowerLabel.state(source: .battery, isCharging: false) == "On battery")
    }

    /// A machine at 100% on wall power is plugged in and not charging.
    /// "On battery" there is simply false, and it is the state a person
    /// checks the panel to confirm.
    @Test func pluggedInAndFullIsNotOnBattery() {
        #expect(PowerLabel.state(source: .wall, isCharging: false) == "Plugged in")
    }

    /// Charging is impossible on battery power, so the flag is ignored
    /// rather than believed.
    @Test func batteryPowerIsNeverReportedAsCharging() {
        #expect(PowerLabel.state(source: .battery, isCharging: true) == "On battery")
    }

    // MARK: - Nothing to estimate

    /// Plugged in and not charging is not "estimating" — there is nothing
    /// to estimate, and there never will be until charging starts. A row
    /// that says "Estimating…" forever is the same dishonesty as one that
    /// shows a stale number.
    @Test func pluggedInAndNotChargingSaysSoRatherThanEstimating() {
        #expect(PowerLabel.timeRemainingValue(
            minutes: nil, source: .wall, isCharging: false) == "Not charging")
    }

    /// While charging, an absent estimate really is still being worked out.
    @Test func chargingWithNoEstimateIsStillEstimating() {
        #expect(PowerLabel.timeRemainingValue(
            minutes: nil, source: .wall, isCharging: true) == "Estimating…")
    }

    @Test func onBatteryTheValueIsTheDuration() {
        #expect(PowerLabel.timeRemainingValue(
            minutes: 135, source: .battery, isCharging: false) == "2:15")
        #expect(PowerLabel.timeRemainingValue(
            minutes: nil, source: .battery, isCharging: false) == "Estimating…")
    }

    // MARK: - The row's own title

    /// Time remaining and time until full are different questions, and
    /// labelling a charging machine "Time remaining" reads as a countdown
    /// to empty while the cable is plugged in.
    @Test func theRowIsTitledForTheDirectionOfTravel() {
        #expect(PowerLabel.timeRemainingTitle(source: .battery) == "Time remaining")
        #expect(PowerLabel.timeRemainingTitle(source: .wall) == "Until full")
    }
}
