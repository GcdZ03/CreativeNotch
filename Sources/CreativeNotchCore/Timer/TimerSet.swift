import Foundation

/// One countdown among several, with an identity that survives pausing.
public struct RunningTimer: Equatable, Sendable, Identifiable {
    public let id: Int
    public var countdown: Countdown

    public init(id: Int, countdown: Countdown) {
        self.id = id
        self.countdown = countdown
    }
}

/// Up to `capacity` concurrent countdowns, as a value.
///
/// Each member is an ordinary `Countdown` — a stored target date, never a
/// tick — and every answer here is derived from those and a `now` passed
/// in, so the whole set is testable by passing timestamps.
///
/// **One wake for the whole set.** `nextWake` is the earliest of each
/// member's own `TimerSchedule` answer, and `TimerController` keeps the one
/// cancel-and-replace one-shot it always had, aimed at that instant. There
/// is no timer per countdown: three countdowns cost the wakes of whichever
/// is busiest at the moment, not three schedules side by side.
///
/// The list keeps **start order**, deliberately not soonest-first. The tab
/// lists them, and a row that jumped when its neighbour was paused would
/// put a different timer's Cancel under the pointer that just clicked
/// Pause. Only the ear sorts, and it shows one (`soonest`).
public struct TimerSet: Equatable, Sendable {

    /// Three. Enough for tea, laundry and a meeting; more than that is a
    /// list manager, and the tab has room for three rows at every text
    /// size.
    public static let capacity = 3

    public private(set) var all: [RunningTimer] = []
    private var nextID = 0

    public init() {}

    public var isEmpty: Bool { all.isEmpty }
    public var isFull: Bool { all.count >= Self.capacity }

    public func timer(_ id: Int) -> RunningTimer? {
        all.first { $0.id == id }
    }

    /// Adds a countdown and returns its id, or `nil` when the set is full
    /// or the duration is one `Countdown` refuses. Full refuses rather than
    /// replacing: dropping a running countdown to make room would lose one
    /// the user set.
    @discardableResult
    public mutating func add(duration: TimeInterval, at now: Date) -> Int? {
        guard !isFull, let countdown = Countdown(duration: duration, startingAt: now) else {
            return nil
        }
        let id = nextID
        nextID += 1
        all.append(RunningTimer(id: id, countdown: countdown))
        return id
    }

    public mutating func pause(id: Int, at now: Date) {
        update(id) { $0.paused(at: now) }
    }

    public mutating func resume(id: Int, at now: Date) {
        update(id) { $0.resumed(at: now) }
    }

    public mutating func remove(id: Int) {
        all.removeAll { $0.id == id }
    }

    public mutating func pauseAll(at now: Date) {
        for i in all.indices { all[i].countdown = all[i].countdown.paused(at: now) }
    }

    public mutating func resumeAll(at now: Date) {
        for i in all.indices { all[i].countdown = all[i].countdown.resumed(at: now) }
    }

    public mutating func removeAll() {
        all.removeAll()
    }

    /// The id of the countdown the ear shows.
    ///
    /// A running countdown outranks every paused one — a paused countdown
    /// is not approaching anything — then the least remaining wins, and a
    /// tie goes to the one started first so the ear never flickers between
    /// two that finish together. With everything paused it is still the
    /// one closest to done, drawn dimmed.
    public func soonestID(at now: Date) -> Int? {
        all.enumerated().min { a, b in
            let ka = (a.element.countdown.isPaused, a.element.countdown.remaining(at: now), a.offset)
            let kb = (b.element.countdown.isPaused, b.element.countdown.remaining(at: now), b.offset)
            if ka.0 != kb.0 { return !ka.0 }
            if ka.1 != kb.1 { return ka.1 < kb.1 }
            return ka.2 < kb.2
        }?.element.id
    }

    public func soonest(at now: Date) -> Countdown? {
        soonestID(at: now).flatMap { timer($0)?.countdown }
    }

    /// Takes out every countdown whose deadline has passed and returns
    /// them in the order they finished, so each gets its own completion —
    /// chime, peek and announcement. A paused countdown never finishes.
    public mutating func removeFinished(at now: Date) -> [Countdown] {
        let done = all
            .filter { $0.countdown.hasFinished(at: now) }
            .sorted { $0.countdown.remaining(at: now) < $1.countdown.remaining(at: now) }
        guard !done.isEmpty else { return [] }
        let ids = Set(done.map(\.id))
        all.removeAll { ids.contains($0.id) }
        return done.map(\.countdown)
    }

    /// Seconds until the next wake for the whole set: the earliest member
    /// wake from `TimerSchedule`, or `nil` when nothing needs one. Paused
    /// members contribute nothing, so an all-paused set schedules nothing.
    public func nextWake(isActive: Bool, at now: Date) -> TimeInterval? {
        all.compactMap {
            TimerSchedule.nextWake(countdown: $0.countdown, isActive: isActive, at: now)
        }.min()
    }

    private mutating func update(_ id: Int, _ change: (Countdown) -> Countdown) {
        guard let i = all.firstIndex(where: { $0.id == id }) else { return }
        all[i].countdown = change(all[i].countdown)
    }
}
