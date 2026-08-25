import Foundation
import Testing
@testable import CreativeNotchCore

/// The notch stays silent when Apple's HUD is already showing, which means
/// knowing a change came from a keypress. Nothing exposes whether Apple's
/// HUD is on screen, so the keypress is what gets detected — and a keypress
/// and the value change it causes are separate events that have to be
/// correlated.
struct HUDAttributionTests {

    @Test func theWindowIsWhatTheSpecSays() {
        #expect(HUDAttribution.window == 0.25)
    }

    @Test func noKeyEverSeenMeansTheChangeCameFromElsewhere() {
        #expect(HUDAttribution.isKeyDriven(changeAt: 100, lastKeyAt: nil) == false)
    }

    @Test func aKeyJustBeforeTheChangeClaimsIt() {
        #expect(HUDAttribution.isKeyDriven(changeAt: 100.1, lastKeyAt: 100.0))
    }

    @Test func aKeyLongBeforeTheChangeDoesNot() {
        #expect(HUDAttribution.isKeyDriven(changeAt: 105, lastKeyAt: 100) == false)
    }

    /// Exactly at the window the key still claims it; a moment past and it
    /// does not. Without this, `<` and `<=` are indistinguishable.
    @Test func theBoundaryIsInclusive() {
        #expect(HUDAttribution.isKeyDriven(changeAt: 100 + HUDAttribution.window, lastKeyAt: 100))
        #expect(HUDAttribution.isKeyDriven(changeAt: 100 + HUDAttribution.window + 0.001, lastKeyAt: 100) == false)
    }

    /// Clocks are not guaranteed monotonic across sources. A key stamped
    /// after the change it supposedly caused is nonsense, not a match.
    @Test func aKeyAfterTheChangeIsNotACause() {
        #expect(HUDAttribution.isKeyDriven(changeAt: 100, lastKeyAt: 100.1) == false)
    }

    /// `delta == 0` — the key and the change land at the exact same
    /// timestamp. Without this case, mutating `delta >= 0` to `delta > 0`
    /// passes every other test in this file silently.
    @Test func aKeyAtTheExactSameInstantClaimsIt() {
        #expect(HUDAttribution.isKeyDriven(changeAt: 100, lastKeyAt: 100))
    }
}
