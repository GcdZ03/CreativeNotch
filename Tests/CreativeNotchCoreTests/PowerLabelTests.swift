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
        #expect(PowerLabel.state(source: .wall, isCharging: true, isCharged: false)
                == "Charging")
        #expect(PowerLabel.state(source: .battery, isCharging: false, isCharged: false)
                == "On battery")
    }

    /// Plugged in, not charging, not full — macOS's own wording for this
    /// is "Not charging", and it happens for real: measured on this
    /// machine at 52% with the adapter attached and the battery actually
    /// draining (`Current = -383`). Saying "Plugged in" there tells the
    /// user the cable is in, which they can see, and hides the thing they
    /// would want to know.
    @Test func pluggedInAndNotChargingSaysNotCharging() {
        #expect(PowerLabel.state(source: .wall, isCharging: false, isCharged: false)
                == "Not charging")
    }

    /// But a machine that is simply full is not "not charging" in any
    /// sense a person would recognise — it has finished.
    @Test func aFullBatteryReadsAsCharged() {
        #expect(PowerLabel.state(source: .wall, isCharging: false, isCharged: true)
                == "Fully charged")
    }

    /// Charging is impossible on battery power, so the flags are ignored
    /// rather than believed.
    @Test func batteryPowerIsNeverReportedAsCharging() {
        #expect(PowerLabel.state(source: .battery, isCharging: true, isCharged: true)
                == "On battery")
    }

    // MARK: - Nothing to estimate

    /// Plugged in and not charging is not "estimating" — there is nothing
    /// to estimate, and there never will be until charging starts. A row
    /// that says "Estimating…" forever is the same dishonesty as one that
    /// shows a stale number.
    ///
    /// It must not repeat the state either. The line above already says
    /// "Not charging"; a row that says it twice is noise, and a row
    /// *titled* "Until full" whose value is "Not charging" contradicts its
    /// own label — which is what shipped and what this pins.
    @Test func pluggedInAndNotChargingHasNothingToReport() {
        #expect(PowerLabel.timeRemainingValue(
            minutes: nil, source: .wall, isCharging: false) == "—")
    }

    /// The title and the value must never contradict each other. "Until
    /// full" is a promise that a filling time is coming; it is only asked
    /// while something is actually filling.
    @Test func theTitleNeverPromisesWhatTheValueCannotAnswer() {
        // Not charging: the title must not say "Until full".
        #expect(PowerLabel.timeRemainingTitle(source: .wall, isCharging: false)
                != "Until full")
        // Charging: it should.
        #expect(PowerLabel.timeRemainingTitle(source: .wall, isCharging: true)
                == "Until full")
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
        #expect(PowerLabel.timeRemainingTitle(source: .battery, isCharging: false)
                == "Time remaining")
        #expect(PowerLabel.timeRemainingTitle(source: .wall, isCharging: true)
                == "Until full")
    }
}
