import Foundation
import Testing
@testable import CreativeNotchCore

/// The five power changes worth interrupting for, and where they sit in
/// the one peek slot.
struct PowerEventTests {

    @Test func aPowerEventCanOccupyThePeekSlot() {
        let content = PeekContent.power(.unplugged(level: 66))

        #expect(content == .power(.unplugged(level: 66)))
        #expect(content != .power(.pluggedIn(level: 66)))
    }

    @Test func lowBatteryCarriesBothItsThresholdAndTheLevel() {
        #expect(PowerEvent.lowBattery(threshold: 20, level: 19)
                != PowerEvent.lowBattery(threshold: 20, level: 18))
        #expect(PowerEvent.lowBattery(threshold: 20, level: 19)
                != PowerEvent.lowBattery(threshold: 10, level: 19))
    }

    /// Low Power Mode turning *off* is as much a state change as it
    /// turning on — the machine has resumed full performance, and that is
    /// the same kind of unrequested behaviour change.
    @Test func lowPowerModeIsAnEventInBothDirections() {
        #expect(PowerEvent.lowPowerMode(enabled: true)
                != PowerEvent.lowPowerMode(enabled: false))
    }
}
