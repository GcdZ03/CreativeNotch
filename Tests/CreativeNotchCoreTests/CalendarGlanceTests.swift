import Foundation
import Testing
@testable import CreativeNotchCore

/// The calendar glance's every judgement, on fixed dates.
///
/// No clock is read anywhere in here: every function takes `now` and a
/// `Calendar`, the way `Countdown` and `PeekArbiter` do, so a test pins the
/// instant, the time zone and the locale and the answer cannot drift with the
/// machine running it.
enum CalendarFixture {
    /// A Berlin calendar, so "today" and "midnight" are not UTC's by accident.
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }()

    /// A 24-hour locale, so times read "10:30" rather than "10:30 AM".
    static let locale = Locale(identifier: "en_GB")

    /// Wednesday 21 October 2026 at `hour:minute` in Berlin, `dayOffset` days on.
    static func date(_ hour: Int, _ minute: Int = 0, dayOffset: Int = 0) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 10
        components.day = 21 + dayOffset
        components.hour = hour
        components.minute = minute
        return calendar.date(from: components)!
    }

    static func event(
        _ title: String,
        start: Date,
        end: Date,
        allDay: Bool = false,
        calendarTitle: String = "Work"
    ) -> CalendarEvent {
        CalendarEvent(
            id: title,
            title: title,
            start: start,
            end: end,
            isAllDay: allDay,
            calendarTitle: calendarTitle,
            color: CalendarColor(red: 0.2, green: 0.5, blue: 0.9)
        )
    }

    /// An all-day event as EventKit reports one: midnight to the next midnight.
    static func allDay(_ title: String, dayOffset: Int = 0, days: Int = 1) -> CalendarEvent {
        event(title, start: date(0, dayOffset: dayOffset), end: date(0, dayOffset: dayOffset + days), allDay: true)
    }
}

private typealias F = CalendarFixture

// MARK: - Which events show

struct CalendarUpcomingTests {

    @Test func showsTheNextThreeInStartOrder() {
        let now = F.date(9)
        let events = [
            F.event("Lunch", start: F.date(12), end: F.date(13)),
            F.event("Standup", start: F.date(9, 30), end: F.date(9, 45)),
            F.event("Review", start: F.date(15), end: F.date(16)),
            F.event("Retro", start: F.date(17), end: F.date(18)),
        ]
        let upcoming = CalendarGlance.upcoming(events, now: now, calendar: F.calendar)
        #expect(upcoming.map(\.title) == ["Standup", "Lunch", "Review"])
    }

    /// A meeting that has ended is gone; one under way is still the most
    /// useful row there is.
    @Test func dropsWhatHasEndedAndKeepsWhatIsUnderWay() {
        let now = F.date(10)
        let events = [
            F.event("Finished", start: F.date(8), end: F.date(9)),
            F.event("Ends now", start: F.date(9), end: F.date(10)),
            F.event("Under way", start: F.date(9, 30), end: F.date(10, 30)),
        ]
        let upcoming = CalendarGlance.upcoming(events, now: now, calendar: F.calendar)
        #expect(upcoming.map(\.title) == ["Under way"])
    }

    /// Today and tomorrow, and nothing after: the day after tomorrow is not a
    /// glance any more.
    @Test func looksNoFurtherThanTheEndOfTomorrow() {
        let now = F.date(22)
        let events = [
            F.event("Tomorrow late", start: F.date(23, 30, dayOffset: 1), end: F.date(23, 45, dayOffset: 1)),
            F.event("Day after", start: F.date(0, 15, dayOffset: 2), end: F.date(1, dayOffset: 2)),
        ]
        let upcoming = CalendarGlance.upcoming(events, now: now, calendar: F.calendar)
        #expect(upcoming.map(\.title) == ["Tomorrow late"])
    }

    /// All-day events are context, not appointments. Sorted by start they
    /// would all land at midnight, ahead of every meeting, and a holiday and
    /// a birthday could push the next meeting off a three-row glance.
    @Test func allDayEventsComeAfterTheTimedOnesOfTheirDay() {
        let now = F.date(9)
        let events = [
            F.allDay("Holiday"),
            F.event("Standup", start: F.date(9, 30), end: F.date(9, 45)),
            F.allDay("Offsite", dayOffset: 1),
            F.event("Early tomorrow", start: F.date(8, dayOffset: 1), end: F.date(9, dayOffset: 1)),
        ]
        let upcoming = CalendarGlance.upcoming(events, now: now, calendar: F.calendar, limit: 4)
        #expect(upcoming.map(\.title) == ["Standup", "Holiday", "Early tomorrow", "Offsite"])
    }

    /// An all-day event that began last week belongs to today, not to the day
    /// it started on.
    @Test func aMultiDayEventCountsAsToday() {
        let now = F.date(9)
        let events = [
            F.event("Tomorrow", start: F.date(8, dayOffset: 1), end: F.date(9, dayOffset: 1)),
            F.event("Conference", start: F.date(0, dayOffset: -3), end: F.date(0, dayOffset: 2), allDay: true),
        ]
        let upcoming = CalendarGlance.upcoming(events, now: now, calendar: F.calendar)
        #expect(upcoming.map(\.title) == ["Conference", "Tomorrow"])
    }

    /// Two events at the same minute keep one order between refreshes rather
    /// than swapping rows on every redraw.
    @Test func tiesAreBrokenByTitleSoTheOrderIsStable() {
        let now = F.date(9)
        let a = F.event("Beta", start: F.date(10), end: F.date(11))
        let b = F.event("Alpha", start: F.date(10), end: F.date(11))
        #expect(CalendarGlance.upcoming([a, b], now: now, calendar: F.calendar).map(\.title) == ["Alpha", "Beta"])
        #expect(CalendarGlance.upcoming([b, a], now: now, calendar: F.calendar).map(\.title) == ["Alpha", "Beta"])
    }

    @Test func theFetchWindowRunsFromMidnightTodayToMidnightAfterTomorrow() {
        let window = CalendarGlance.fetchWindow(now: F.date(15, 20), calendar: F.calendar)
        #expect(window.start == F.date(0))
        #expect(window.end == F.date(0, dayOffset: 2))
    }
}

// MARK: - Reminders

struct CalendarReminderTallyTests {

    private func reminder(_ due: Date?, hasTime: Bool = true, done: Bool = false) -> CalendarReminder {
        CalendarReminder(id: UUID().uuidString, title: "r", due: due, hasTime: hasTime, isCompleted: done)
    }

    @Test func countsWhatIsDueTodayAndWhatIsOverdue() {
        let now = F.date(12)
        let reminders = [
            reminder(F.date(9)),                          // overdue: earlier today
            reminder(F.date(16)),                         // due later today
            reminder(F.date(10, dayOffset: -2)),          // overdue: two days ago
            reminder(F.date(9, dayOffset: 1)),            // tomorrow: not counted
            reminder(nil),                                // no date: not counted
            reminder(F.date(8), done: true),              // done: not counted
        ]
        let tally = CalendarGlance.tally(reminders, now: now, calendar: F.calendar)
        #expect(tally == ReminderTally(dueToday: 1, overdue: 2))
        #expect(tally.total == 3)
    }

    /// A reminder due "today" with no time is due all day: it is not overdue
    /// at nine in the morning, and it is overdue tomorrow.
    @Test func aDateOnlyReminderIsOverdueOnlyOnceItsDayHasPassed() {
        let today = reminder(F.date(0), hasTime: false)
        let yesterday = reminder(F.date(0, dayOffset: -1), hasTime: false)
        let tally = CalendarGlance.tally([today, yesterday], now: F.date(21), calendar: F.calendar)
        #expect(tally == ReminderTally(dueToday: 1, overdue: 1))
    }
}

// MARK: - When the glance next changes

struct CalendarBoundaryTests {

    /// The next instant the rows would read differently: an event starting
    /// or ending, a reminder falling due, or midnight moving the window.
    @Test func theNextBoundaryIsTheEarliestStartOrEnd() {
        let now = F.date(9)
        let events = [
            F.event("Lunch", start: F.date(12), end: F.date(13)),
            F.event("Under way", start: F.date(8, 30), end: F.date(9, 40)),
        ]
        #expect(CalendarGlance.nextBoundary(after: now, events: events, reminders: [], calendar: F.calendar)
                == F.date(9, 40))
    }

    @Test func withNothingAheadTheBoundaryIsMidnight() {
        let now = F.date(18)
        #expect(CalendarGlance.nextBoundary(after: now, events: [], reminders: [], calendar: F.calendar)
                == F.date(0, dayOffset: 1))
    }

    /// An instant already past, or exactly now, is no boundary: scheduling
    /// for it would wake at once, find nothing new, and schedule it again.
    @Test func instantsAtOrBeforeNowAreIgnored() {
        let now = F.date(10)
        let events = [F.event("Starts now", start: F.date(10), end: F.date(11))]
        #expect(CalendarGlance.nextBoundary(after: now, events: events, reminders: [], calendar: F.calendar)
                == F.date(11))
    }

    /// A timed reminder falling due turns "due" into "overdue". A date-only
    /// one changes at midnight, which is already a boundary.
    @Test func aTimedReminderFallingDueIsABoundary() {
        let now = F.date(10)
        let reminders = [
            CalendarReminder(id: "a", title: "a", due: F.date(10, 20), hasTime: true, isCompleted: false),
            CalendarReminder(id: "b", title: "b", due: F.date(0), hasTime: false, isCompleted: false),
        ]
        #expect(CalendarGlance.nextBoundary(after: now, events: [], reminders: reminders, calendar: F.calendar)
                == F.date(10, 20))
    }

    /// Inside the hour a row counts down, so its next whole minute is a
    /// boundary: at 09:02 "in 28 min" becomes "in 27 min" at 09:03.
    @Test func aCountdownsNextMinuteIsABoundary() {
        let events = [F.event("Standup", start: F.date(9, 30), end: F.date(9, 45))]
        #expect(CalendarGlance.nextBoundary(after: F.date(9, 2), events: events, reminders: [], calendar: F.calendar)
                == F.date(9, 3))
        // Mid-minute: 27.5 minutes to go reads "in 28 min" until 27 remain.
        let midMinute = F.date(9, 2).addingTimeInterval(30)
        #expect(CalendarGlance.nextBoundary(after: midMinute, events: events, reminders: [], calendar: F.calendar)
                == F.date(9, 3))
    }

    /// An event further off starts counting down an hour before it starts:
    /// at 08:00 "10:30–11:00" next changes at 09:30, to "in 60 min".
    @Test func comingWithinTheHourIsABoundary() {
        let events = [F.event("Review", start: F.date(10, 30), end: F.date(11))]
        #expect(CalendarGlance.nextBoundary(after: F.date(8), events: events, reminders: [], calendar: F.calendar)
                == F.date(9, 30))
    }

    /// All-day rows never count down, and a row for tomorrow reads
    /// "Tomorrow 00:30" until midnight: neither adds a wake.
    @Test func allDayAndTomorrowAddNoCountdownWakes() {
        let events = [
            F.allDay("Holiday"),
            F.event("Late", start: F.date(0, 30, dayOffset: 1), end: F.date(1, dayOffset: 1)),
        ]
        #expect(CalendarGlance.nextBoundary(after: F.date(23), events: events, reminders: [], calendar: F.calendar)
                == F.date(0, dayOffset: 1))
    }

    /// Walked from 08:00 to the start, every boundary is an instant the row
    /// reads differently, and nothing changes in between -- the pane never
    /// shows a stale count and never wakes for nothing.
    @Test func everyBoundaryChangesTheRowAndNothingChangesBetween() {
        let event = F.event("Review", start: F.date(10, 30), end: F.date(11))
        func text(_ at: Date) -> String {
            CalendarText.when(event, now: at, calendar: F.calendar, locale: F.locale)
        }
        var now = F.date(8)
        var wakes = 0
        while now < event.start {
            let next = CalendarGlance.nextBoundary(after: now, events: [event], reminders: [], calendar: F.calendar)
            #expect(text(next.addingTimeInterval(-0.5)) == text(now), "changed before \(next)")
            #expect(text(next) != text(now), "nothing changed at \(next)")
            now = next
            wakes += 1
        }
        // 09:30, then one per minute from "in 60 min" down to the start.
        #expect(wakes == 61)
    }

    /// Never later than midnight, whatever is scheduled for next week.
    @Test func midnightCapsTheBoundary() {
        let now = F.date(23)
        let events = [F.event("Tomorrow", start: F.date(9, dayOffset: 1), end: F.date(10, dayOffset: 1))]
        #expect(CalendarGlance.nextBoundary(after: now, events: events, reminders: [], calendar: F.calendar)
                == F.date(0, dayOffset: 1))
    }
}

// MARK: - What it says

struct CalendarTextTests {

    private func when(_ event: CalendarEvent, at now: Date) -> String {
        CalendarText.when(event, now: now, calendar: F.calendar, locale: F.locale)
    }

    @Test func soonIsCountedInMinutes() {
        let event = F.event("Standup", start: F.date(9, 30), end: F.date(9, 45))
        #expect(when(event, at: F.date(9, 15)) == "in 15 min")
        // Rounded up: 30 seconds to go still reads "in 1 min", never "in 0 min".
        #expect(when(event, at: F.date(9, 30).addingTimeInterval(-30)) == "in 1 min")
    }

    /// More than an hour away, the time itself is more use than a count.
    /// The count begins at exactly an hour, an instant the boundary can
    /// wake for.
    @Test func laterTodayIsATimeRange() {
        let event = F.event("Review", start: F.date(10, 30), end: F.date(11))
        #expect(when(event, at: F.date(9, 29)) == "10:30\u{2013}11:00")
        #expect(when(event, at: F.date(9, 30)) == "in 60 min")
        #expect(when(event, at: F.date(9, 31)) == "in 59 min")
    }

    @Test func underWaySaysUntilWhen() {
        let event = F.event("Workshop", start: F.date(9), end: F.date(11, 30))
        #expect(when(event, at: F.date(10)) == "Now, until 11:30")
    }

    @Test func tomorrowSaysSo() {
        let event = F.event("Dentist", start: F.date(10, 15, dayOffset: 1), end: F.date(11, dayOffset: 1))
        #expect(when(event, at: F.date(16)) == "Tomorrow 10:15")
    }

    @Test func allDayEventsSayAllDay() {
        #expect(when(F.allDay("Holiday"), at: F.date(9)) == "All day")
        #expect(when(F.allDay("Offsite", dayOffset: 1), at: F.date(9)) == "Tomorrow, all day")
    }

    /// The locale decides the clock, not this code: a 12-hour locale gets
    /// its own format rather than a hard-coded "HH:mm".
    @Test func theLocaleChoosesTheClock() {
        let event = F.event("Review", start: F.date(14, 30), end: F.date(15))
        let text = CalendarText.when(event, now: F.date(9), calendar: F.calendar, locale: Locale(identifier: "en_US"))
        #expect(text.contains("PM"))
    }

    /// VoiceOver hears words, not "in 15 min" or an en dash.
    @Test func theSpokenFormIsASentence() {
        let soon = F.event("Standup", start: F.date(9, 30), end: F.date(9, 45))
        #expect(CalendarText.spoken(soon, now: F.date(9, 15), calendar: F.calendar, locale: F.locale)
                == "Standup, in 15 minutes, Work calendar")
        let one = F.event("Standup", start: F.date(9, 30), end: F.date(9, 45))
        #expect(CalendarText.spoken(one, now: F.date(9, 29), calendar: F.calendar, locale: F.locale)
                == "Standup, in 1 minute, Work calendar")
        let later = F.event("Review", start: F.date(10, 30), end: F.date(11))
        #expect(CalendarText.spoken(later, now: F.date(9), calendar: F.calendar, locale: F.locale)
                == "Review, 10:30 to 11:00, Work calendar")
        #expect(CalendarText.spoken(F.allDay("Holiday"), now: F.date(9), calendar: F.calendar, locale: F.locale)
                == "Holiday, all day, Work calendar")
        let tomorrow = F.event("Dentist", start: F.date(10, 15, dayOffset: 1), end: F.date(11, dayOffset: 1))
        #expect(CalendarText.spoken(tomorrow, now: F.date(9), calendar: F.calendar, locale: F.locale)
                == "Dentist, tomorrow at 10:15, Work calendar")
        let now = F.event("Workshop", start: F.date(9), end: F.date(11, 30))
        #expect(CalendarText.spoken(now, now: F.date(10), calendar: F.calendar, locale: F.locale)
                == "Workshop, now, until 11:30, Work calendar")
    }

    @Test func theReminderLineCountsAndSaysWhatIsOverdue() {
        #expect(CalendarText.reminders(ReminderTally(dueToday: 0, overdue: 0)) == "No reminders due today")
        #expect(CalendarText.reminders(ReminderTally(dueToday: 1, overdue: 0)) == "1 reminder due today")
        #expect(CalendarText.reminders(ReminderTally(dueToday: 2, overdue: 1)) == "3 reminders due \u{00B7} 1 overdue")
        #expect(CalendarText.reminders(ReminderTally(dueToday: 0, overdue: 2)) == "2 reminders overdue")
    }

    /// The pane's title row says which day "today" is, in the locale's words.
    @Test func theDayLabelIsTheLocalesShortDate() {
        #expect(CalendarText.day(F.date(9), calendar: F.calendar, locale: F.locale) == "Wed 21 Oct")
        // Midnight in Berlin is still the 21st there, whatever UTC says.
        #expect(CalendarText.day(F.date(0, 30), calendar: F.calendar, locale: F.locale) == "Wed 21 Oct")
    }

    /// An event with no title still gets a row that says something.
    @Test func anUntitledEventIsNamedAsSuch() {
        #expect(CalendarText.title(of: F.event("", start: F.date(10), end: F.date(11))) == "New Event")
        #expect(CalendarText.title(of: F.event("  ", start: F.date(10), end: F.date(11))) == "New Event")
        #expect(CalendarText.title(of: F.event("Standup", start: F.date(10), end: F.date(11))) == "Standup")
    }
}

// MARK: - Access

struct CalendarAccessTests {

    @Test func eitherGrantShowsTheGlance() {
        #expect(CalendarPane.resolve(events: .granted, reminders: .granted)
                == .glance(showsEvents: true, showsReminders: true))
        #expect(CalendarPane.resolve(events: .granted, reminders: .denied)
                == .glance(showsEvents: true, showsReminders: false))
        #expect(CalendarPane.resolve(events: .denied, reminders: .granted)
                == .glance(showsEvents: false, showsReminders: true))
    }

    /// Nothing granted yet and something still undecided: ask. The pane's
    /// button asks; the app never prompts on its own at launch.
    @Test func anUndecidedAccessWithNothingGrantedAsks() {
        #expect(CalendarPane.resolve(events: .notDetermined, reminders: .notDetermined) == .needsAccess)
        #expect(CalendarPane.resolve(events: .notDetermined, reminders: .denied) == .needsAccess)
    }

    /// Refused outright: the explanatory state, with the way to System
    /// Settings. Restricted is said differently, because Settings cannot
    /// change it.
    @Test func refusalIsExplainedAndRestrictionIsToo() {
        #expect(CalendarPane.resolve(events: .denied, reminders: .denied) == .denied)
        #expect(CalendarPane.resolve(events: .denied, reminders: .restricted) == .denied)
        #expect(CalendarPane.resolve(events: .restricted, reminders: .restricted) == .restricted)
    }

    @Test func onlyAnUndecidedAccessIsWorthRequesting() {
        #expect(CalendarAccess.notDetermined.isRequestable)
        for access: CalendarAccess in [.granted, .denied, .restricted] {
            #expect(!access.isRequestable)
        }
    }
}
