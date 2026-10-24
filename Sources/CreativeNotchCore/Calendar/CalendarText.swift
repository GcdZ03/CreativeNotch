import Foundation

/// What the glance says, in words for the eye and in sentences for VoiceOver.
///
/// Times go through the locale's own short time format, never a hard-coded
/// "HH:mm": a 12-hour locale gets "2:30 PM", a 24-hour one "14:30".
public enum CalendarText {

    /// An hour or less away, a count reads faster than a time. Exactly an
    /// hour reads "in 60 min", so the count begins at an instant
    /// (`start - countdownHorizon`) that `CalendarGlance.nextBoundary` can
    /// wake for, rather than just after one.
    static let countdownHorizon: TimeInterval = 60 * 60

    /// The row's right-hand side: "in 15 min", "10:30–11:00",
    /// "Now, until 11:30", "Tomorrow 08:15", "All day".
    public static func when(_ event: CalendarEvent, now: Date, calendar: Calendar, locale: Locale) -> String {
        let isTomorrow = startsTomorrow(event, now: now, calendar: calendar)
        if event.isAllDay {
            return isTomorrow ? "Tomorrow, all day" : "All day"
        }
        if event.start <= now {
            return sameDay(event, calendar: calendar)
                ? "Now, until \(time(event.end, calendar: calendar, locale: locale))"
                : "Now"
        }
        if isTomorrow {
            return "Tomorrow \(time(event.start, calendar: calendar, locale: locale))"
        }
        if let minutes = minutesUntil(event, now: now) {
            return "in \(minutes) min"
        }
        let start = time(event.start, calendar: calendar, locale: locale)
        guard sameDay(event, calendar: calendar) else { return start }
        return "\(start)\u{2013}\(time(event.end, calendar: calendar, locale: locale))"
    }

    /// The row as VoiceOver reads it: title, when, and which calendar --
    /// the colour dot's meaning, which nobody can hear.
    public static func spoken(_ event: CalendarEvent, now: Date, calendar: Calendar, locale: Locale) -> String {
        let when: String
        let isTomorrow = startsTomorrow(event, now: now, calendar: calendar)
        if event.isAllDay {
            when = isTomorrow ? "tomorrow, all day" : "all day"
        } else if event.start <= now {
            when = sameDay(event, calendar: calendar)
                ? "now, until \(time(event.end, calendar: calendar, locale: locale))"
                : "now"
        } else if isTomorrow {
            when = "tomorrow at \(time(event.start, calendar: calendar, locale: locale))"
        } else if let minutes = minutesUntil(event, now: now) {
            when = minutes == 1 ? "in 1 minute" : "in \(minutes) minutes"
        } else if sameDay(event, calendar: calendar) {
            when = "\(time(event.start, calendar: calendar, locale: locale)) to \(time(event.end, calendar: calendar, locale: locale))"
        } else {
            when = time(event.start, calendar: calendar, locale: locale)
        }
        return "\(title(of: event)), \(when), \(event.calendarTitle) calendar"
    }

    /// The line under the rows. The overdue figure is part of the total, so
    /// "3 reminders due · 1 overdue" is three reminders, not four.
    public static func reminders(_ tally: ReminderTally) -> String {
        let total = tally.total
        let noun = total == 1 ? "reminder" : "reminders"
        if total == 0 { return "No reminders due today" }
        if tally.overdue == 0 { return "\(total) \(noun) due today" }
        if tally.dueToday == 0 { return "\(total) \(noun) overdue" }
        return "\(total) \(noun) due \u{00B7} \(tally.overdue) overdue"
    }

    /// The row's title. Calendar names an untitled event "New Event", so the
    /// glance does too rather than drawing an empty row.
    public static func title(of event: CalendarEvent) -> String {
        let trimmed = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "New Event" : trimmed
    }

    /// Today, for the pane's title row: "Wed 21 Oct" in British English,
    /// "Wed, Oct 21" in American -- the locale's own order.
    public static func day(_ now: Date, calendar: Calendar, locale: Locale) -> String {
        var style = Date.FormatStyle().weekday(.abbreviated).day().month(.abbreviated)
        style.locale = locale
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return now.formatted(style)
    }

    // MARK: - Pieces

    /// Whole minutes until the start, rounded up so the last half-minute
    /// reads "in 1 min" rather than "in 0 min"; `nil` past the horizon.
    /// Internal so `CalendarGlance.nextBoundary` schedules by the same rule
    /// the row is written by.
    static func minutesUntil(_ event: CalendarEvent, now: Date) -> Int? {
        let seconds = event.start.timeIntervalSince(now)
        guard seconds > 0, seconds <= countdownHorizon else { return nil }
        return Int((seconds / 60).rounded(.up))
    }

    private static func startsTomorrow(_ event: CalendarEvent, now: Date, calendar: Calendar) -> Bool {
        let today = calendar.startOfDay(for: now)
        guard event.start >= today,
              let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else { return false }
        return calendar.isDate(event.start, inSameDayAs: tomorrow)
    }

    /// Whether the event ends on the day it starts, so a range "10:30–11:00"
    /// cannot mean 11:00 the next morning.
    private static func sameDay(_ event: CalendarEvent, calendar: Calendar) -> Bool {
        calendar.isDate(event.start, inSameDayAs: event.end)
    }

    private static func time(_ date: Date, calendar: Calendar, locale: Locale) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.locale = locale
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }
}
