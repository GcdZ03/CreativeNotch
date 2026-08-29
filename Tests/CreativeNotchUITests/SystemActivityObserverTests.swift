import AppKit
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// The AppKit half of spec section 4.7. All judgement lives in
/// `SystemActivityReducer`; this only translates notification names, so
/// what is tested here is the translation and the lifecycle.
@MainActor
struct SystemActivityObserverTests {

    @Test func itStartsActive() {
        #expect(SystemActivityObserver().activity == .active)
    }

    @Test func lockingIsReported() {
        let observer = SystemActivityObserver()
        var seen: [SystemActivity] = []
        observer.onChange = { seen.append($0) }

        observer.handle(.screenLocked)

        #expect(observer.activity == .locked)
        #expect(seen == [.locked])
    }

    @Test func theFullSleepCycleIsReported() {
        let observer = SystemActivityObserver()
        var seen: [SystemActivity] = []
        observer.onChange = { seen.append($0) }

        observer.handle(.willSleep)
        observer.handle(.screenLocked)
        observer.handle(.didWake)
        observer.handle(.screenUnlocked)

        #expect(seen == [.asleep, .locked, .active])
        #expect(observer.activity == .active)
    }

    /// Only *changes* are reported. `screenIsLocked` can be delivered more
    /// than once, and the consumer tears down and rebuilds a timer on each
    /// call — so a repeat would restart the poll clock for no reason.
    @Test func unchangedActivityIsNotReported() {
        let observer = SystemActivityObserver()
        var count = 0
        observer.onChange = { _ in count += 1 }

        observer.handle(.screenLocked)
        observer.handle(.screenLocked)

        #expect(count == 1)
    }

    /// `start()` and `stop()` must register and remove the *same* set.
    /// Three observers in this codebase have shipped a `stop()` that
    /// forgot one of them; each was found by a test shaped like this.
    @Test func stoppingRemovesEverythingStartingAdded() {
        let observer = SystemActivityObserver()
        #expect(observer.tokenCount == 0)

        observer.start()
        #expect(observer.tokenCount == 4)

        observer.stop()
        #expect(observer.tokenCount == 0)
    }

    @Test func startingTwiceDoesNotStackObservers() {
        let observer = SystemActivityObserver()
        observer.start()
        observer.start()

        #expect(observer.tokenCount == 4)
        observer.stop()
        #expect(observer.tokenCount == 0)
    }

    @Test func stoppingWithoutStartingIsHarmless() {
        let observer = SystemActivityObserver()
        observer.stop()
        #expect(observer.tokenCount == 0)
    }
}
