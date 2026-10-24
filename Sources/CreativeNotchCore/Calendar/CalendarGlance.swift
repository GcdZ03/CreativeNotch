import Foundation

/// How many reminders need attention today.
public struct ReminderTally: Equatable, Sendable {
    /// Due later today, not yet late.
    public var dueToday: Int
    /// Past due: earlier today for a timed reminder, an earlier day for any.
    public var overdue: Int

    public init(dueToday: Int, overdue: Int) {
        self.dueToday = dueToday
        self.overdue = overdue
    }

    public var total: Int { dueToday + overdue }
}

/// Every judgement the calendar glance makes, as pure functions of a `now`
/// and a `Calendar` passed in.
///
/// Taking the clock and the calendar as parameters is what lets the tests pin
/// a Wednesday in Berlin and get the same answer on any machine, at any hour
/// -- the reason `Countdown.remaining(at:)` and `PeekArbiter.content(now:)`
/// take theirs. Do not replace either with `Date()` or `.current`.
public enum CalendarGlance {

    /// Today and tomorrow: from midnight this morning to midnight after
    /// tomorrow, in `calendar`'s time zone. What the controller asks EventKit
    /// for; which of it shows is `upcoming`'s decision, made at draw time.
    public static func fetchWindow(now: Date, calendar: Calendar) -> DateInterval {
        let today = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 2, to: today) ?? today.addingTimeInterval(2 * 86_400)
        return DateInterval(start: today, end: end)
    }

    /// The next `limit` events worth a row: not yet ended, starting before
    /// the end of tomorrow.
    ///
    /// Ordered by day, then timed before all-day, then start, then title.
    /// **All-day events come after the timed ones of their day.** They are
    /// context rather than appointments, and sorted purely by start every one
    /// of them would land at midnight, ahead of every meeting -- a holiday and
    /// a birthday would push the next meeting off a three-row glance. An event
    /// that started on an earlier day (a conference, a trip) counts as today.
    /// The title breaks ties so two events at the same minute keep one order
    /// between redraws.
    public static func upcoming(
        _ events: [CalendarEvent], now: Date, calendar: Calendar, limit: Int = 3
    ) -> [CalendarEvent] {
        let window = fetchWindow(now: now, calendar: calendar)
        let today = window.start
        let live = events.filter { $0.end > now && $0.start < window.end }
        func day(_ event: CalendarEvent) -> Int {
            calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: max(event.start, today))).day ?? 0
        }
        let sorted = live.sorted { a, b in
            let (da, db) = (day(a), day(b))
            if da != db { return da < db }
            if a.isAllDay != b.isAllDay { return !a.isAllDay }
            if a.start != b.start { return a.start < b.start }
            if a.title != b.title { return a.title < b.title }
            return a.id < b.id
        }
        return Array(sorted.prefix(max(0, limit)))
    }

    /// Incomplete reminders that are due today or late. Undated and
    /// completed reminders count for nothing, and so does anything due
    /// tomorrow or later.
    ///
    /// A reminder with no time is due all day: "today" is not overdue at
    /// 21:00, and becomes overdue at midnight.
    public static func tally(_ reminders: [CalendarReminder], now: Date, calendar: Calendar) -> ReminderTally {
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86_400)
        var tally = ReminderTally(dueToday: 0, overdue: 0)
        for reminder in reminders where !reminder.isCompleted {
            guard let due = reminder.due, due < tomorrow else { continue }
            let late = reminder.hasTime ? due < now : due < today
            if late { tally.overdue += 1 } else { tally.dueToday += 1 }
        }
        return tally
    }

    /// The next instant the glance would read differently: an event starting
    /// (its row stops counting down and reads "Now") or ending (it drops
    /// out), an event coming within `CalendarText.countdownHorizon`
    /// ("10:30–11:00" becomes "in 60 min"), a counting-down row's next whole
    /// minute ("in 28 min" becomes "in 27 min"), a timed reminder falling
    /// due (it turns overdue), or midnight (today becomes yesterday and the
    /// window moves). Never later than
    /// midnight, and never at or before `now` -- an instant already reached
    /// would wake at once, find nothing new, and schedule itself again.
    ///
    /// The controller sleeps until exactly this instant, once, and only
    /// while the pane is on screen: the schedule the timer established
    /// (`TimerDisplay.nextChange`), where the display's own granularity is
    /// the redraw schedule and nothing wakes in between.
    public static func nextBoundary(
        after now: Date, events: [CalendarEvent], reminders: [CalendarReminder], calendar: Calendar
    ) -> Date {
        let today = calendar.startOfDay(for: now)
        let midnight = calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86_400)
        var candidates = [midnight]
        for event in events {
            candidates.append(event.start)
            candidates.append(event.end)
            // Only a timed event starting today counts down: an all-day row
            // never does, and one starting tomorrow reads "Tomorrow 08:15"
            // until midnight, which is already a candidate.
            guard !event.isAllDay, event.start > now, event.start < midnight else { continue }
            if let minutes = CalendarText.minutesUntil(event, now: now) {
                // "in m min" holds while more than m-1 minutes remain. At
                // m == 1 this is the start itself, already a candidate.
                candidates.append(event.start.addingTimeInterval(-Double(minutes - 1) * 60))
            } else {
                candidates.append(event.start.addingTimeInterval(-CalendarText.countdownHorizon))
            }
        }
        for reminder in reminders where !reminder.isCompleted && reminder.hasTime {
            if let due = reminder.due { candidates.append(due) }
        }
        return candidates.filter { $0 > now }.min().map { min($0, midnight) } ?? midnight
    }
}
