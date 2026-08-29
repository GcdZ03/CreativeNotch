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

    /// The unclamped sequence would reach 32s at attempt 6; the ceiling brings
    /// it back to 30s. The test directly exercises the ceiling because with
    /// maxAttempts == 5 the attempt-bounded API never reaches the cap.
    @Test func theClampingFunctionEnforcesTheCap() {
        #expect(HelperBackoff.clamped(64) == 30)
        #expect(HelperBackoff.clamped(30) == 30)
        #expect(HelperBackoff.clamped(16) == 16)
        #expect(HelperBackoff.clamped(1) == 1)
    }

    /// Proves the ceiling exists because it is needed: the unclamped doubling
    /// would exceed the cap if maxAttempts were ever raised.
    @Test func theExponentialSequenceExceedsTheCapAtAttemptSix() {
        #expect(HelperBackoff.exponentialDelay(forAttempt: 5) == 16)
        #expect(HelperBackoff.exponentialDelay(forAttempt: 6) == 32)
    }

    @Test func attemptZeroOrNegativeIsNonsenseAndYieldsNil() {
        #expect(HelperBackoff.delay(forAttempt: 0) == nil)
        #expect(HelperBackoff.delay(forAttempt: -1) == nil)
    }
}
