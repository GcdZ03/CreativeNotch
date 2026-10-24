import Foundation

/// A calendar's colour, as plain sRGB components.
///
/// Not a `CGColor` or a SwiftUI `Color`: Core imports neither, and a value
/// type is what lets an event compare equal across refreshes, so an
/// unchanged calendar republishes nothing the view has to redraw for.
public struct CalendarColor: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// What an event whose calendar reports no colour is drawn with.
    public static let fallback = CalendarColor(red: 0.6, green: 0.6, blue: 0.6)
}

/// One event, copied out of EventKit into a value.
///
/// The copy is the point: an `EKEvent` is a live, non-`Sendable` object
/// owned by a store, and a glance built from values can be judged by pure
/// functions with fixed dates (`CalendarGlance`) and drawn without a store
/// anywhere near the view.
public struct CalendarEvent: Equatable, Sendable, Identifiable {
    /// Unique per occurrence, so a repeating event's rows do not collide.
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    /// The calendar's name, for VoiceOver: the colour dot alone says nothing
    /// to someone who cannot see it.
    public var calendarTitle: String
    public var color: CalendarColor

    public init(
        id: String,
        title: String,
        start: Date,
        end: Date,
        isAllDay: Bool,
        calendarTitle: String,
        color: CalendarColor
    ) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.calendarTitle = calendarTitle
        self.color = color
    }
}

/// One reminder, copied out of EventKit into a value, like `CalendarEvent`.
public struct CalendarReminder: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    /// When it is due, or `nil` for a reminder with no date.
    public var due: Date?
    /// Whether `due` carries a time of day. A reminder due "Friday" is due
    /// all of Friday; one due "Friday 15:00" is overdue at 15:01.
    public var hasTime: Bool
    public var isCompleted: Bool

    public init(id: String, title: String, due: Date?, hasTime: Bool, isCompleted: Bool) {
        self.id = id
        self.title = title
        self.due = due
        self.hasTime = hasTime
        self.isCompleted = isCompleted
    }
}

/// Which of EventKit's two permissions a question is about. They are two
/// separate grants in System Settings, and a person may give one and not
/// the other.
public enum CalendarEntity: CaseIterable, Equatable, Sendable {
    case events
    case reminders
}

/// What the app may read, per entity, in the app's own words rather than
/// EventKit's `EKAuthorizationStatus`, so Core can decide what to show
/// without importing EventKit.
///
/// EventKit's write-only grant maps to `.denied`: it lets an app add events
/// and read none, and a glance that cannot read has nothing to show.
public enum CalendarAccess: Equatable, Sendable {
    case notDetermined
    case granted
    case denied
    case restricted

    /// Only an undecided access is worth a request. Asking again after a
    /// refusal shows no prompt -- macOS answers from the stored decision --
    /// so a button that "asks" would silently do nothing.
    public var isRequestable: Bool { self == .notDetermined }
}

/// Everything one refresh read, for the pane to draw.
///
/// The raw events in the fetch window, not the three rows: which three show,
/// and what each says ("in 15 min"), depend on the instant the pane is drawn
/// at, and the view passes that instant in -- so a snapshot fetched a minute
/// ago still draws the right rows now.
public struct CalendarSnapshot: Equatable, Sendable {
    public var eventsAccess: CalendarAccess
    public var remindersAccess: CalendarAccess
    public var events: [CalendarEvent]
    public var reminders: [CalendarReminder]
    /// When this was read. Part of equality on purpose: a refresh at an
    /// event boundary can read exactly the events it read before, and
    /// `@Observable` drops an assignment equal to the stored value -- the
    /// trap `AppState.countdown`'s box exists for. A new instant makes each
    /// refresh a new value, so the pane redraws at the boundary it was
    /// scheduled for.
    public var refreshedAt: Date

    public init(
        eventsAccess: CalendarAccess,
        remindersAccess: CalendarAccess,
        events: [CalendarEvent] = [],
        reminders: [CalendarReminder] = [],
        refreshedAt: Date
    ) {
        self.eventsAccess = eventsAccess
        self.remindersAccess = remindersAccess
        self.events = events
        self.reminders = reminders
        self.refreshedAt = refreshedAt
    }

    /// What the pane shows for these grants.
    public var pane: CalendarPane {
        CalendarPane.resolve(events: eventsAccess, reminders: remindersAccess)
    }
}

/// What the calendar pane shows, decided from the two grants alone.
public enum CalendarPane: Equatable, Sendable {
    /// Nothing granted, something undecided: an "Allow Access…" button.
    case needsAccess
    /// Refused: why there is nothing, and the way to System Settings.
    case denied
    /// Restricted by a profile or Screen Time: said plainly, with no button,
    /// because System Settings cannot change it.
    case restricted
    /// At least one grant: the rows and the reminder line, each only where
    /// its grant allows.
    case glance(showsEvents: Bool, showsReminders: Bool)

    /// Any grant shows what it can; only with nothing granted does the pane
    /// ask or explain. Asking wins over explaining while anything is still
    /// undecided, because the request is the one route that can still end
    /// in a grant without a trip to System Settings.
    public static func resolve(events: CalendarAccess, reminders: CalendarAccess) -> CalendarPane {
        if events == .granted || reminders == .granted {
            return .glance(showsEvents: events == .granted, showsReminders: reminders == .granted)
        }
        if events.isRequestable || reminders.isRequestable { return .needsAccess }
        if events == .restricted && reminders == .restricted { return .restricted }
        return .denied
    }
}
