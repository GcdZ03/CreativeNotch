import Foundation
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// Several countdowns and the stopwatch, connected to the app through the
/// delegate's real wiring rather than a controller a test built itself.
@MainActor
struct StopwatchTimersWiringTests {

    // MARK: - Several countdowns

    /// The tab lists every countdown, so `AppState` carries the list as well
    /// as the soonest the ear draws — through the same publish path.
    @Test func everyCountdownReachesTheState() throws {
        let delegate = NotchedDelegate.make()
        delegate.state.onStartTimer?(1500)
        delegate.state.onStartTimer?(300)

        #expect(delegate.state.timers.map(\.countdown.duration) == [1500, 300])
        // The ear's countdown is the soonest.
        #expect(delegate.state.countdown?.duration == 300)
    }

    /// The row verbs reach one countdown each through `AppState`.
    @Test func theRowVerbsActOnOneCountdown() throws {
        let delegate = NotchedDelegate.make()
        delegate.state.onStartTimer?(1500)
        delegate.state.onStartTimer?(300)
        let ids = delegate.state.timers.map(\.id)

        delegate.state.onPauseTimer?(ids[0])
        #expect(delegate.state.timers.first?.countdown.isPaused == true)
        #expect(delegate.state.timers.last?.countdown.isPaused == false)

        delegate.state.onResumeTimer?(ids[0])
        #expect(delegate.state.timers.first?.countdown.isPaused == false)

        delegate.state.onCancelTimer?(ids[1])
        #expect(delegate.state.timers.map(\.id) == [ids[0]])
        #expect(delegate.state.countdown?.duration == 1500)
    }

    /// Starting from the add picker returns to the list: the picker exists
    /// to start one, and leaving it up would offer a fourth that the cap
    /// would refuse.
    @Test func startingAnotherClosesTheAddPicker() {
        let delegate = NotchedDelegate.make()
        delegate.state.onStartTimer?(1500)
        delegate.state.isAddingTimer = true

        delegate.state.onStartTimer?(300)
        #expect(!delegate.state.isAddingTimer)
    }

    /// When the last countdown goes, the picker flag goes with it, so the
    /// next countdown starts from the plain single-timer view.
    @Test func cancellingTheLastCountdownClearsTheAddPicker() throws {
        let delegate = NotchedDelegate.make()
        delegate.state.onStartTimer?(1500)
        delegate.state.isAddingTimer = true
        let id = try #require(delegate.state.timers.first?.id)

        delegate.state.onCancelTimer?(id)
        #expect(!delegate.state.isAddingTimer)
    }

    // MARK: - The stopwatch

    @Test func installingWiresTheStopwatch() {
        #expect(NotchedDelegate.make().state.onStopwatch != nil)
    }

    /// The stopwatch is a value in `AppState`, moved at the delegate's
    /// injected clock — nothing schedules, so nothing here has to wait.
    @Test func theStopwatchVerbsMoveTheValueAtTheDelegatesClock() throws {
        let delegate = NotchedDelegate.make()
        var t: TimeInterval = 1_000
        delegate.now = { t }

        delegate.state.onStopwatch?(.start)
        #expect(delegate.state.stopwatch.isRunning)

        t += 42
        delegate.state.onStopwatch?(.lap)
        #expect(delegate.state.stopwatch.laps == [42])

        t += 8
        delegate.state.onStopwatch?(.pause)
        #expect(delegate.state.stopwatch.elapsed(at: Date(timeIntervalSince1970: t + 500)) == 50)

        delegate.state.onStopwatch?(.reset)
        #expect(delegate.state.stopwatch.isReset)
    }

    // MARK: - The toggle

    /// Switching the timer off leaves running countdowns to finish (they
    /// chime — the user set them), but a stopwatch has nothing to finish
    /// and no tab left to read it from, so it is reset rather than left
    /// counting invisibly. Its verb goes with the tab's other verbs.
    @Test func switchingTheTimerOffResetsTheStopwatchAndDropsItsVerb() {
        let delegate = NotchedDelegate.make()
        delegate.state.onStopwatch?(.start)
        delegate.state.timerMode = .stopwatch
        delegate.state.isAddingTimer = true

        delegate.switchboard.setEnabled(false, for: .timer)
        #expect(delegate.state.onStopwatch == nil)
        #expect(delegate.state.stopwatch.isReset)
        #expect(delegate.state.timerMode == .timer)
        #expect(!delegate.state.isAddingTimer)

        delegate.switchboard.setEnabled(true, for: .timer)
        #expect(delegate.state.onStopwatch != nil)
    }

    /// The countdowns themselves survive the toggle, as the single one did.
    @Test func switchingTheTimerOffLeavesEveryCountdownRunning() {
        let delegate = NotchedDelegate.make()
        delegate.state.onStartTimer?(1500)
        delegate.state.onStartTimer?(300)

        delegate.switchboard.setEnabled(false, for: .timer)
        #expect(delegate.timer?.timers.all.count == 2)
    }

    /// Quitting cancels every countdown, not just the soonest.
    @Test func stopAllCancelsEveryCountdown() {
        let delegate = NotchedDelegate.make()
        delegate.state.onStartTimer?(1500)
        delegate.state.onStartTimer?(300)

        delegate.switchboard.stopAll()
        #expect(delegate.timer?.timers.isEmpty == true)
        #expect(delegate.timer?.scheduledWake == nil)
    }
}
