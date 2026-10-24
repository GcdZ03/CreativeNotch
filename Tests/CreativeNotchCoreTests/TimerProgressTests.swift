import Foundation
import Testing
@testable import CreativeNotchCore

/// The track under the digits is a function of the same instant they are.
struct TimerProgressTests {
    let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    @Test func aFreshCountdownIsEmpty() throws {
        let c = try #require(Countdown(duration: 600, startingAt: t0))
        #expect(TimerProgress.fraction(c, at: t0) == 0)
    }

    @Test func halfwayIsHalf() throws {
        let c = try #require(Countdown(duration: 600, startingAt: t0))
        #expect(TimerProgress.fraction(c, at: t0.addingTimeInterval(300)) == 0.5)
    }

    @Test func aFinishedCountdownIsFullAndNeverOverflows() throws {
        let c = try #require(Countdown(duration: 600, startingAt: t0))
        #expect(TimerProgress.fraction(c, at: t0.addingTimeInterval(900)) == 1)
    }

    @Test func aPausedCountdownHoldsItsFraction() throws {
        let c = try #require(Countdown(duration: 600, startingAt: t0))
            .paused(at: t0.addingTimeInterval(150))
        #expect(TimerProgress.fraction(c, at: t0.addingTimeInterval(150)) == 0.25)
        #expect(TimerProgress.fraction(c, at: t0.addingTimeInterval(500)) == 0.25)
    }
}

/// The gauge's fill colour, decided once.
struct PowerGaugeToneTests {
    @Test func chargingWinsOverLow() {
        #expect(PowerGaugeTone.tone(level: 5, isCharging: true) == .charging)
    }

    @Test func atOrBelowTheMacOSThresholdIsLow() {
        #expect(PowerGaugeTone.tone(level: 20, isCharging: false) == .low)
        #expect(PowerGaugeTone.tone(level: 21, isCharging: false) == .normal)
    }

    /// The same 20 the low-battery peek arms on. One threshold, spelled once.
    @Test func theThresholdIsTheArmingModulesTopThreshold() {
        #expect(PowerGaugeTone.lowThreshold == LowBatteryArming.thresholds.max())
    }

    /// Colour is not the only signal (Differentiate Without Color). The
    /// charging bolt is shown always, as the menu bar's own battery does;
    /// the low mark only under the setting, where yellow alone is not
    /// enough. Normal carries no glyph either way.
    @Test func eachToneHasItsNonColourCue() {
        #expect(PowerGaugeTone.charging.glyph(differentiateWithoutColor: false) == "bolt.fill")
        #expect(PowerGaugeTone.charging.glyph(differentiateWithoutColor: true) == "bolt.fill")
        #expect(PowerGaugeTone.low.glyph(differentiateWithoutColor: false) == nil)
        #expect(PowerGaugeTone.low.glyph(differentiateWithoutColor: true) == "exclamationmark")
        #expect(PowerGaugeTone.normal.glyph(differentiateWithoutColor: false) == nil)
        #expect(PowerGaugeTone.normal.glyph(differentiateWithoutColor: true) == nil)
    }
}
