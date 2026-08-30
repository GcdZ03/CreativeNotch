import Foundation
import Testing
@testable import CreativeNotchCore

/// The boundary value between IOKit and every decision in this module.
struct PowerSnapshotTests {

    private func snapshot(
        level: Int = 50,
        source: PowerSource = .battery,
        isCharging: Bool = false,
        isCharged: Bool = false,
        isLowPowerMode: Bool = false
    ) -> PowerSnapshot {
        PowerSnapshot(
            level: level,
            source: source,
            isCharging: isCharging,
            isCharged: isCharged,
            isLowPowerMode: isLowPowerMode
        )
    }

    /// Plugged in is about the *source*, not about charging. A machine at
    /// 100% on wall power is plugged in and not charging, and a UI that
    /// derives one from the other shows "on battery" while the charger is
    /// attached.
    @Test func pluggedInFollowsTheSourceNotTheChargingFlag() {
        #expect(snapshot(source: .wall, isCharging: false).isPluggedIn)
        #expect(snapshot(source: .wall, isCharging: true).isPluggedIn)
        #expect(snapshot(source: .battery, isCharging: false).isPluggedIn == false)
    }


    @Test func snapshotsCompareByValue() {
        #expect(snapshot() == snapshot())
        #expect(snapshot(level: 50) != snapshot(level: 51))
        #expect(snapshot(isLowPowerMode: false) != snapshot(isLowPowerMode: true))
        #expect(snapshot(isCharging: false) != snapshot(isCharging: true))
        #expect(snapshot(isCharged: false) != snapshot(isCharged: true))
    }
}
