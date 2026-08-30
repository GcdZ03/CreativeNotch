import Foundation
import Testing
@testable import CreativeNotchCore

/// The one string this module shows.
///
/// It used to show several — a formatted duration, an "Estimating…"
/// placeholder, a row title that changed with the direction of charge.
/// All of that went with the time-remaining row. What is left is the
/// question the panel actually answers: what is the machine doing.
struct PowerLabelTests {

    @Test func stateNamesWhatIsActuallyHappening() {
        #expect(PowerLabel.state(source: .wall, isCharging: true, isCharged: false)
                == "Charging")
        #expect(PowerLabel.state(source: .battery, isCharging: false, isCharged: false)
                == "On battery")
    }

    /// Plugged in, not charging, not full — macOS's own wording for this
    /// is "Not charging", and it happens for real: measured on this
    /// machine at 52% with the adapter attached and the battery actually
    /// draining (`Current = -383`). `IOPSKeys.h` documents it as
    /// legitimate rather than exceptional.
    ///
    /// Saying "Plugged in" there tells the user the cable is in, which
    /// they can see, and hides the thing they would want to know.
    @Test func pluggedInAndNotChargingSaysNotCharging() {
        #expect(PowerLabel.state(source: .wall, isCharging: false, isCharged: false)
                == "Not charging")
    }

    /// But a machine that is simply full is not "not charging" in any
    /// sense a person would recognise — it has finished. `IOPSKeys.h`:
    /// "a battery with capacity >= 95% and not charging is defined as
    /// charged", so this is not the same fact as `!isCharging` and not
    /// the same as 100%.
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

    /// Four distinct states. Two of them sharing a string would make the
    /// panel unable to tell the user apart the case where charging has
    /// finished from the case where it never started.
    @Test func everyStateReadsDifferently() {
        let all = [
            PowerLabel.state(source: .wall, isCharging: true, isCharged: false),
            PowerLabel.state(source: .wall, isCharging: false, isCharged: true),
            PowerLabel.state(source: .wall, isCharging: false, isCharged: false),
            PowerLabel.state(source: .battery, isCharging: false, isCharged: false),
        ]

        #expect(Set(all).count == all.count)
    }
}
