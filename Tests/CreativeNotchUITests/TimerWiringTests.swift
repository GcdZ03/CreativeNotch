import AppKit
import Foundation
import Observation
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// That the timer module is actually connected to the app, rather than
/// merely existing beside it.
///
/// The two modules before this one each shipped their bug here and not in
/// their logic: a `setActivity` leg deleted from the fan-out left 471 tests
/// green while the media helper ran through lock and sleep, and the
/// clipboard was unreachable because its tab was not offered. Everything
/// below is a leg of the wiring, tested through the delegate's real
/// methods rather than through a controller a test built itself.
///
/// Built on `NotchedDelegate`, so the widths here are the same widths
/// `NowPlayingBadgeTests` and `TimerBadgeTests` pin, on the same synthetic
/// notched screen: panel-local closed rect (195, 222, 230, 38).
@MainActor
struct TimerWiringTests {

    /// `onChange` is `@Sendable`, so a captured `var` cannot be mutated
    /// from it. A reference box is the usual way around that in a test —
    /// the same one `ShelfStoreObservationTests` uses.
    private final class Flag: @unchecked Sendable {
        var value = false
    }

    /// 25 minutes from the wall clock, so it is still running at every
    /// `Date()` any of these tests takes — `NotchRootView.drawnRect(for:)`
    /// and `AppDelegate.currentBadgeWidth` each read the clock themselves.
    ///
    /// Deliberately *not* a fixed instant in the past. The brief's draft
    /// used `Date(timeIntervalSinceReferenceDate: 1_000_000)`, which is in
    /// 2001: a countdown starting there has already finished, so
    /// `NotchShape.badgeSlot` returns `.none` and every width assertion
    /// below would have measured the un-badged notch.
    private static func running() -> Countdown {
        Countdown(duration: 1500, startingAt: Date())!
    }

    // MARK: - The badge, through the real publish path

    /// The countdown badge grows the closed shape, so all three derived
    /// rects have to agree while it shows: what is drawn, what accepts
    /// clicks, and what tracks hover.
    ///
    /// `TimerBadgeTests` proves the same 274 by seeding `state.countdown`
    /// before `install`, which is a path the running app never takes. This
    /// one goes through `countdownDidChange`, which is the only path it
    /// does take — and `AppState`'s funnel does not fire for a countdown
    /// tick, it carries state and geometry and a tick is neither. Drop the
    /// `syncTrackingRect()` from `countdownDidChange` and this fails while
    /// `TimerBadgeTests` stays green.
    @Test func theDrawnHitTestAndHoverRectsAgreeWhileACountdownShows() throws {
        let delegate = NotchedDelegate.make()
        delegate.countdownDidChange(Self.running())

        let drawn = NotchRootView.drawnRect(for: delegate.state)
        let accepted = delegate.acceptedRect
        let tracking = delegate.hoverView?.trackingRect

        // The drawn rect is in SwiftUI's top-left space; the other two are
        // panel-local bottom-left. Same rectangle, mirrored in y.
        #expect(drawn.size == accepted.size)
        #expect(drawn.minX == accepted.minX)
        #expect(drawn.minY == delegate.currentFrame.height - accepted.maxY)
        #expect(tracking == accepted)

        // And genuinely the badged shape, so it cannot pass with all three
        // agreeing on the un-badged one. 230 + 44, written out for the
        // reason `TimerBadgeTests.timedRect` gives.
        #expect(drawn.width == 274)
        #expect(accepted == CGRect(x: 195, y: 222, width: 274, height: 38))
    }

    /// The regression half: a timer width leaking into one consumer while
    /// no timer runs would swallow menu bar clicks beside the notch.
    @Test func theSameRectsAgreeWithNoTimer() {
        let delegate = NotchedDelegate.make()
        let drawn = NotchRootView.drawnRect(for: delegate.state)

        #expect(delegate.acceptedRect.width == 230)
        #expect(drawn.width == 230)
        #expect(delegate.hoverView?.trackingRect == delegate.acceptedRect)
    }

    /// Cancelling has to take the width back, not merely fail to add more.
    /// The re-sync runs on every publish, not only the first — the same
    /// property `pausingAfterPlayingTakesTheBadgeBack` pins for media.
    @Test func cancellingGivesTheEarBackToTheMenuBar() {
        let delegate = NotchedDelegate.make()
        delegate.countdownDidChange(Self.running())
        #expect(delegate.acceptedRect.width == 274)

        delegate.countdownDidChange(nil)

        #expect(delegate.acceptedRect.width == 230)
        #expect(delegate.hoverView?.trackingRect.width == 230)
        #expect(NotchRootView.drawnRect(for: delegate.state).width == 230)
    }

    // MARK: - The `@Observable` trap

    /// A display-change wake republishes a countdown that is `==` to the
    /// one already there — same `target`, same `duration`, same
    /// `pausedRemaining` — because what changed is the wall clock, and the
    /// clock is not part of the value. SwiftUI still has to be told, or the
    /// number in the ear freezes while the timer runs on underneath.
    ///
    /// This is not a hypothetical guard somebody might add later. Swift's
    /// `@Observable` macro emits that equality guard *itself* for every
    /// `Equatable` stored property, and `Countdown` is `Equatable` — on
    /// Swift 6.3 this test failed the first time it was run, against a
    /// plain stored `var countdown: Countdown?`. The non-`Equatable`
    /// `CountdownPublication` box in `AppState` is what fixes it; deleting
    /// the box, or conforming it to `Equatable`, brings the frozen ear
    /// straight back.
    ///
    /// Nothing else in the suite can catch that: every other test asserts a
    /// *value*, and the value would still be right — the timer would still
    /// finish, chime and peek on time. `withObservationTracking` is the
    /// same mechanism SwiftUI uses, so this asks the real question rather
    /// than a proxy for it.
    @Test func aDisplayChangeWakeStillReachesTheView() throws {
        let delegate = NotchedDelegate.make()
        let countdown = Self.running()
        delegate.countdownDidChange(countdown)

        // The premise, asserted rather than assumed: the republished value
        // really is equal, so an equality guard really would drop it.
        #expect(delegate.state.countdown == countdown)

        let flag = Flag()
        withObservationTracking {
            _ = delegate.state.countdown
        } onChange: {
            flag.value = true
        }

        delegate.countdownDidChange(countdown)

        #expect(
            flag.value,
            "an equality guard on AppState.countdown freezes the ear silently"
        )
    }

    // MARK: - Finishing

    /// A finished timer has to reach the arbiter, not just the controller —
    /// otherwise it fires silently and nothing is ever drawn.
    @Test func finishingRecordsACompletionWithTheArbiter() throws {
        let delegate = NotchedDelegate.make()
        let finished = try #require(
            Countdown(duration: 60, startingAt: Date().addingTimeInterval(-60))
        )
        delegate.timerDidFinish(finished)

        let content = delegate.arbiter.content(now: delegate.now())
        guard case .timerDone(let completion) = try #require(content) else {
            Issue.record("expected .timerDone, got \(String(describing: content))")
            return
        }
        #expect(completion.duration == 60)
    }

    /// And it is drawn: recording into the arbiter without presenting would
    /// leave the completion sitting there until something else peeked.
    @Test func finishingPresentsTheCompletionPeek() throws {
        let delegate = NotchedDelegate.make()
        delegate.timerDidFinish(try #require(
            Countdown(duration: 60, startingAt: Date().addingTimeInterval(-60))
        ))

        guard case .peek(.timerDone) = delegate.state.state else {
            Issue.record("expected a .timerDone peek, got \(delegate.state.state)")
            return
        }
    }

    /// Lateness is measured from the clock, not assumed zero. This is what
    /// makes "finished 2h ago" true after the machine slept through it.
    @Test func aTimerThatFiredLateReportsItsLateness() throws {
        let delegate = NotchedDelegate.make()
        // Expired well in the past: 60s duration started two hours ago.
        let stale = try #require(
            Countdown(duration: 60, startingAt: Date().addingTimeInterval(-7200))
        )
        delegate.timerDidFinish(stale)

        let content = delegate.arbiter.content(now: delegate.now())
        guard case .timerDone(let completion) = try #require(content) else {
            Issue.record("expected .timerDone")
            return
        }
        #expect(completion.lateness > 7000)
    }

    /// Never negative. A timer that fires a hair *early* — the one-shot
    /// waking a few microseconds before the target — must report "just
    /// now", not a negative interval `TimerCompletionText` would have to
    /// find words for.
    @Test func aTimerThatFiredOnTimeReportsNoLateness() throws {
        let delegate = NotchedDelegate.make()
        // Target a second in the future: `remaining` is positive, so the
        // unclamped negation is negative.
        let early = try #require(Countdown(duration: 60, startingAt: Date()))
        delegate.timerDidFinish(early)

        let content = delegate.arbiter.content(now: delegate.now())
        guard case .timerDone(let completion) = try #require(content) else {
            Issue.record("expected .timerDone")
            return
        }
        #expect(completion.lateness == 0)
    }

    /// `TimerChime` was built by task 8 and called by nothing. It belongs
    /// in the finish handler, and this is what says so.
    ///
    /// Counted through `AppDelegate.playChime` rather than by listening for
    /// a sound: no test may make the machine audible. The hook's default is
    /// `TimerChime.play` itself, so what is left uncovered is one
    /// initialiser expression and nothing more.
    @Test func finishingPlaysTheChimeExactlyOnce() throws {
        let delegate = NotchedDelegate.make()
        var chimes = 0
        delegate.playChime = { chimes += 1 }

        delegate.timerDidFinish(try #require(
            Countdown(duration: 60, startingAt: Date().addingTimeInterval(-60))
        ))

        #expect(chimes == 1)
    }

    /// A completion must not interrupt an open panel — `presentPeek`
    /// already declines for `.open`, and routing through it is what gets
    /// that behaviour for free rather than by a second rule that has to
    /// stay in step.
    @Test func aCompletionDoesNotTearDownAnOpenPanel() throws {
        let delegate = NotchedDelegate.make()
        delegate.installOutsideClickMonitor = { _ in NSObject() }
        delegate.removeOutsideClickMonitor = { _ in }
        delegate.state.transition(to: .open(.timer))

        delegate.timerDidFinish(try #require(
            Countdown(duration: 60, startingAt: Date().addingTimeInterval(-60))
        ))

        #expect(delegate.state.state == .open(.timer))
    }

    /// Nor a drag. `.receiving` is the other state `presentPeek` declines
    /// for, and tearing a drop target down mid-gesture loses the drop.
    @Test func aCompletionDoesNotTearDownADragInFlight() throws {
        let delegate = NotchedDelegate.make()
        delegate.state.transition(to: .receiving)

        delegate.timerDidFinish(try #require(
            Countdown(duration: 60, startingAt: Date().addingTimeInterval(-60))
        ))

        #expect(delegate.state.state == .receiving)
    }

    /// Opening the panel acknowledges the completion.
    ///
    /// Without the `dismissTimerDone()`, the finished timer sits in the
    /// arbiter for the rest of its ten-minute TTL and reappears on the next
    /// hover — and because it outranks the HUD, volume feedback would be
    /// swallowed by it for ten minutes too.
    @Test func openingThePanelClearsTheCompletion() throws {
        let delegate = NotchedDelegate.make()
        delegate.installOutsideClickMonitor = { _ in NSObject() }
        delegate.removeOutsideClickMonitor = { _ in }

        delegate.timerDidFinish(try #require(
            Countdown(duration: 60, startingAt: Date().addingTimeInterval(-60))
        ))
        #expect(delegate.arbiter.content(now: delegate.now()) != nil)

        delegate.state.transition(to: .open(.timer))

        #expect(delegate.arbiter.content(now: delegate.now()) == nil)
    }

    // MARK: - The controller is built and reachable

    @Test func installingBuildsTheController() {
        #expect(NotchedDelegate.make().timer != nil)
    }

    /// Left unset, every button in the timer tab would be dead on screen
    /// with nothing failing — the exact bug `installingWiresTheMediaHandler`
    /// exists for on the media side.
    @Test func installingWiresTheTabsFourVerbs() {
        let state = NotchedDelegate.make().state
        #expect(state.onStartTimer != nil)
        #expect(state.onPauseTimer != nil)
        #expect(state.onResumeTimer != nil)
        #expect(state.onCancelTimer != nil)
    }

    /// And they reach the controller the app built, through the whole loop:
    /// closure -> controller -> `onChange` -> `countdownDidChange` ->
    /// `AppState.countdown` -> the badge width. A closure wired to the
    /// wrong controller, or to none, stops this dead.
    @Test func theTabsVerbsDriveTheRealController() throws {
        let delegate = NotchedDelegate.make()
        let timer = try #require(delegate.timer)

        delegate.state.onStartTimer?(1500)
        #expect(timer.countdown != nil)
        #expect(delegate.state.countdown != nil)
        #expect(delegate.acceptedRect.width == 274)

        delegate.state.onPauseTimer?()
        #expect(delegate.state.countdown?.isPaused == true)
        // A paused timer schedules nothing at all: that is where the
        // "zero redraws while paused" claim becomes true.
        #expect(timer.scheduledWake == nil)

        delegate.state.onResumeTimer?()
        #expect(delegate.state.countdown?.isPaused == false)

        delegate.state.onCancelTimer?()
        #expect(delegate.state.countdown == nil)
        #expect(delegate.acceptedRect.width == 230)
    }

    // MARK: - The `SystemActivity` exemption

    /// The timer is on the fan-out, and it is on it *differently*.
    ///
    /// The clipboard poller and the media helper stop outside `.active`.
    /// The timer must not: `setActive` changes only how often it wakes to
    /// redraw. Awake it wakes at the next display change (60s into a
    /// 25-minute countdown, when "25m" becomes "24m"); asleep it schedules
    /// the deadline itself and nothing before it — still scheduled, just
    /// not painting against a dark screen.
    ///
    /// Delete `self.timer?.setActive(...)` from `activity.onChange` and the
    /// asleep expectation below fails: the wake stays at 60s and the
    /// machine is woken 24 more times to redraw a screen nobody is looking
    /// at.
    @Test func theActivityGateReachesTheTimerWithoutSuspendingIt() throws {
        let delegate = NotchedDelegate.make()
        // Neither of the other two legs may touch the real machine: the
        // poller must not install a run-loop timer and the supervisor must
        // not spawn or signal a helper process.
        let clipboard = try #require(delegate.clipboard)
        clipboard.poller.scheduleTimer = { _, _ in nil }
        clipboard.poller.cancelTimer = { _ in }
        let media = try #require(delegate.media)
        media.supervisor.startHelper = {}
        media.supervisor.stopHelper = {}

        let timer = try #require(delegate.timer)
        timer.start(duration: 1500)

        // The next display change: 60s into a 25-minute countdown, when
        // "25m" becomes "24m". Not exactly 60 — a sliver of wall time
        // passes between `start`'s clock read and `nextWake`'s.
        let awake = try #require(timer.scheduledWake)
        #expect(
            abs(awake - 60) < 1,
            "awake, the next wake is the next display change, not the deadline"
        )

        delegate.activity.handle(.willSleep)

        let asleep = try #require(
            timer.scheduledWake,
            "the timer must still be scheduled while the machine sleeps"
        )
        #expect(asleep > awake)
        // The deadline, not a display change. Within a second of 1500,
        // since a little wall time passes between the two `start` reads.
        #expect(abs(asleep - 1500) < 5)

        delegate.activity.handle(.didWake)

        #expect(try #require(timer.scheduledWake) <= 60)
        #expect(abs(try #require(timer.scheduledWake) - 60) < 1)
    }
}
