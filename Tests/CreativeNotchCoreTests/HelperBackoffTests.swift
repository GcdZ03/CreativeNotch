import Foundation
import Testing
@testable import CreativeNotchCore

/// How hard to try before giving up on the helper.
///
/// Spec section 5: 1s doubling to a 30s cap, five attempts, then degrade
/// to controls-only. Pure arithmetic so the whole policy is provable
/// without waiting.
struct HelperBackoffTests {

    @Test func thePolicyIsWhatTheSpecSays() {
        #expect(HelperBackoff.maxAttempts == 5)
        #expect(HelperBackoff.cap == 30)
    }

    @Test func itDoublesFromOneSecond() {
        #expect(HelperBackoff.delay(forAttempt: 1) == 1)
        #expect(HelperBackoff.delay(forAttempt: 2) == 2)
        #expect(HelperBackoff.delay(forAttempt: 3) == 4)
        #expect(HelperBackoff.delay(forAttempt: 4) == 8)
        #expect(HelperBackoff.delay(forAttempt: 5) == 16)
    }

    /// Past the last attempt there is no delay because there is no retry —
    /// `nil` is the signal to degrade, not "retry immediately".
    @Test func pastTheLastAttemptThereIsNoDelay() {
        #expect(HelperBackoff.delay(forAttempt: 6) == nil)
        #expect(HelperBackoff.delay(forAttempt: 99) == nil)
    }

    /// Guards the cap even though the doubling sequence does not reach it
    /// within five attempts — the cap must hold if `maxAttempts` is ever
    /// raised.
    @Test func theDelayNeverExceedsTheCap() {
        for attempt in 1...HelperBackoff.maxAttempts {
            if let d = HelperBackoff.delay(forAttempt: attempt) {
                #expect(d <= HelperBackoff.cap)
            }
        }
    }

    @Test func attemptZeroOrNegativeIsNonsenseAndYieldsNil() {
        #expect(HelperBackoff.delay(forAttempt: 0) == nil)
        #expect(HelperBackoff.delay(forAttempt: -1) == nil)
    }
}
