import Foundation
import Testing
@testable import CreativeNotchCore

/// The boundary value between IOKit and every decision in this module.
struct PowerSnapshotTests {

    private func snapshot(
        level: Int = 50,
        source: PowerSource = .battery,
        isCharging: Bool = false,
        estimateMinutes: Int? = 120,
        isLowPowerMode: Bool = false
    ) -> PowerSnapshot {
        PowerSnapshot(
            level: level,
            source: source,
            isCharging: isCharging,
            estimateMinutes: estimateMinutes,
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

    /// `nil` is IOKit's documented "Still Calculating" (-1 in the raw
    /// dictionary), and it must survive as an absence rather than as a
    /// number. A snapshot that reports `-1` minutes is how "-1 minutes
    /// remaining" reaches the panel.
    @Test func anUnknownEstimateIsAbsentRatherThanNegative() {
        #expect(snapshot(estimateMinutes: nil).estimateMinutes == nil)
    }

    @Test func snapshotsCompareByValue() {
        #expect(snapshot() == snapshot())
        #expect(snapshot(level: 50) != snapshot(level: 51))
        #expect(snapshot(estimateMinutes: 120) != snapshot(estimateMinutes: nil))
        #expect(snapshot(isLowPowerMode: false) != snapshot(isLowPowerMode: true))
    }
}
