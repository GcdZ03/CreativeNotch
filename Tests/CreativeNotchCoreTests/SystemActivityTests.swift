import Foundation
import Testing
@testable import CreativeNotchCore

/// Spec section 4.7: "No poller may run outside `.active`. Enforced once,
/// here."
///
/// Sleeping and locking are independent conditions that overlap in normal
/// use — macOS locks the screen *on wake*, so a machine coming back from
/// sleep passes through a state that is both. Collapsing them into one
/// flat value makes `didWake` look like "everything is fine again", which
/// would resume polling with the lock screen still on top of it.
struct SystemActivityTests {

    @Test func aFreshMachineIsActive() {
        #expect(SystemActivityReducer().activity == .active)
    }

    @Test func lockingLeavesActive() {
        var reducer = SystemActivityReducer()
        #expect(reducer.apply(.screenLocked) == .locked)
    }

    @Test func unlockingRestoresActive() {
        var reducer = SystemActivityReducer()
        reducer.apply(.screenLocked)
        #expect(reducer.apply(.screenUnlocked) == .active)
    }

    @Test func sleepingLeavesActive() {
        var reducer = SystemActivityReducer()
        #expect(reducer.apply(.willSleep) == .asleep)
    }

    @Test func wakingRestoresActive() {
        var reducer = SystemActivityReducer()
        reducer.apply(.willSleep)
        #expect(reducer.apply(.didWake) == .active)
    }

    /// The real sequence a closed lid produces. `didWake` arrives while
    /// the lock screen is still up, and must not read as "resume".
    @Test func wakingWhileStillLockedStaysLocked() {
        var reducer = SystemActivityReducer()
        reducer.apply(.willSleep)
        reducer.apply(.screenLocked)
        #expect(reducer.apply(.didWake) == .locked)
        #expect(reducer.apply(.screenUnlocked) == .active)
    }

    /// Sleep outranks lock: a locked machine that then sleeps is asleep,
    /// and unlocking underneath that does not wake it.
    @Test func sleepOutranksLock() {
        var reducer = SystemActivityReducer()
        reducer.apply(.screenLocked)
        #expect(reducer.apply(.willSleep) == .asleep)
        #expect(reducer.apply(.screenUnlocked) == .asleep)
        #expect(reducer.apply(.didWake) == .active)
    }

    /// Notification delivery is not guaranteed to be balanced — a missed
    /// `screenUnlocked` must not leave a permanently suspended poller that
    /// only a relaunch fixes, so the flags are set, never counted.
    @Test func repeatedEventsDoNotStack() {
        var reducer = SystemActivityReducer()
        reducer.apply(.screenLocked)
        reducer.apply(.screenLocked)
        #expect(reducer.apply(.screenUnlocked) == .active)
    }

    @Test func anUnmatchedResumeIsHarmless() {
        var reducer = SystemActivityReducer()
        #expect(reducer.apply(.screenUnlocked) == .active)
        #expect(reducer.apply(.didWake) == .active)
    }
}
