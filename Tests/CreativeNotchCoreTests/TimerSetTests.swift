import Foundation
import Testing
@testable import CreativeNotchCore

/// Several countdowns at once, as a value. Fixed timestamps throughout.
struct TimerSetTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
    private func added(_ set: inout TimerSet, _ duration: TimeInterval) throws -> Int {
        let id = set.add(duration: duration, at: t0)
        return try #require(id)
    }

    @Test func anEmptySetHasNothingToShowOrSchedule() {
        let set = TimerSet()
        #expect(set.isEmpty)
        #expect(set.soonest(at: t0) == nil)
        #expect(set.nextWake(isActive: true, at: t0) == nil)
    }

    @Test func addingKeepsStartOrderAndHandsBackDistinctIDs() throws {
        var set = TimerSet()
        let a = try added(&set, 1500)
        let b = try added(&set, 300)
        #expect(a != b)
        #expect(set.all.map(\.id) == [a, b])
        #expect(set.all.map(\.countdown.duration) == [1500, 300])
    }

    /// Capped, and the cap refuses rather than replacing: dropping a
    /// running countdown to make room would lose one the user set.
    @Test func theSetIsCappedAndRefusesBeyondIt() {
        var set = TimerSet()
        for _ in 0..<TimerSet.capacity { do { let r = set.add(duration: 60, at: t0); #expect(r != nil) } }
        #expect(set.isFull)
        do { let r = set.add(duration: 60, at: t0); #expect(r == nil) }
        #expect(set.all.count == TimerSet.capacity)
    }

    @Test func anInvalidDurationAddsNothing() {
        var set = TimerSet()
        do { let r = set.add(duration: Countdown.maxDuration + 1, at: t0); #expect(r == nil) }
        #expect(set.isEmpty)
    }

    /// The ear shows one: the running countdown that finishes first,
    /// whatever order they were started in.
    @Test func theSoonestIsTheRunningOneThatFinishesFirst() throws {
        var set = TimerSet()
        set.add(duration: 1500, at: t0)
        set.add(duration: 300, at: t0)
        set.add(duration: 900, at: t0)
        #expect(try #require(set.soonest(at: t0)).duration == 300)
    }

    /// A paused countdown is not approaching anything, so a running one
    /// outranks it however much longer the running one has left.
    @Test func aRunningCountdownOutranksAPausedOne() throws {
        var set = TimerSet()
        let short = try added(&set, 60)
        set.add(duration: 1500, at: t0)
        set.pause(id: short, at: at(1))
        #expect(try #require(set.soonest(at: at(1))).duration == 1500)
    }

    /// With everything paused the ear still shows one — dimmed — and it is
    /// the one closest to done.
    @Test func withEverythingPausedTheSoonestIsTheShortestRemainder() throws {
        var set = TimerSet()
        set.add(duration: 600, at: t0)
        set.add(duration: 120, at: t0)
        set.pauseAll(at: at(10))
        let soonest = try #require(set.soonest(at: at(10)))
        #expect(soonest.isPaused)
        #expect(soonest.duration == 120)
    }

    /// Two that finish together tie-break by start order, so the ear does
    /// not flicker between them.
    @Test func aTieGoesToTheOneStartedFirst() throws {
        var set = TimerSet()
        let first = try added(&set, 300)
        set.add(duration: 300, at: t0)
        #expect(set.soonestID(at: t0) == first)
    }

    @Test func pauseResumeAndRemoveActOnOneTimerOnly() throws {
        var set = TimerSet()
        let a = try added(&set, 600)
        let b = try added(&set, 600)

        set.pause(id: a, at: at(100))
        #expect(set.timer(a)?.countdown.isPaused == true)
        #expect(set.timer(b)?.countdown.isPaused == false)

        set.resume(id: a, at: at(400))
        #expect(set.timer(a)?.countdown.remaining(at: at(400)) == 500)

        set.remove(id: b)
        #expect(set.all.map(\.id) == [a])
    }

    @Test func pauseAllAndResumeAllActOnEveryTimer() {
        var set = TimerSet()
        set.add(duration: 600, at: t0)
        set.add(duration: 300, at: t0)
        set.pauseAll(at: at(60))
        #expect(set.all.allSatisfy { $0.countdown.isPaused })
        set.resumeAll(at: at(90))
        #expect(set.all.allSatisfy { !$0.countdown.isPaused })
        #expect(set.all.map { $0.countdown.remaining(at: at(90)) } == [540, 240])
    }

    // MARK: - Completion

    /// Every countdown past its deadline comes out, in the order they
    /// finished, and the rest stay — each gets its own completion.
    @Test func removingFinishedTakesOutOnlyThoseDueInDeadlineOrder() {
        var set = TimerSet()
        set.add(duration: 600, at: t0)
        set.add(duration: 120, at: t0)
        set.add(duration: 60, at: t0)
        let done = set.removeFinished(at: at(200))
        #expect(done.map(\.duration) == [60, 120])
        #expect(set.all.map(\.countdown.duration) == [600])
        #expect(set.removeFinished(at: at(200)).isEmpty)
    }

    @Test func aPausedCountdownNeverFinishes() throws {
        var set = TimerSet()
        let id = try added(&set, 60)
        set.pause(id: id, at: at(30))
        #expect(set.removeFinished(at: at(10_000)).isEmpty)
    }

    // MARK: - Scheduling

    /// One wake for the whole set: the earliest of each countdown's own
    /// `TimerSchedule` answer. A set never asks for more wakes than its
    /// busiest member would alone.
    @Test func theNextWakeIsTheEarliestMemberWake() {
        var set = TimerSet()
        set.add(duration: 1500, at: t0)   // next display change at 60s
        set.add(duration: 30, at: t0)     // next display change at 1s
        #expect(set.nextWake(isActive: true, at: t0) == 1)

        // Screen asleep: deadlines only, and the earliest is 30s away.
        #expect(set.nextWake(isActive: false, at: t0) == 30)
    }

    /// A paused member schedules nothing, so pausing everything schedules
    /// nothing at all — the "zero redraws while paused" claim, for a set.
    @Test func pausedMembersScheduleNothing() throws {
        var set = TimerSet()
        let a = try added(&set, 30)
        set.add(duration: 1500, at: t0)
        set.pause(id: a, at: t0)
        #expect(set.nextWake(isActive: true, at: t0) == 60)
        set.pauseAll(at: t0)
        #expect(set.nextWake(isActive: true, at: t0) == nil)
    }
}
