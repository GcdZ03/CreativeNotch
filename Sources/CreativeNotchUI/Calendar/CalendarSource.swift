import CoreGraphics
import EventKit
import Foundation
import CreativeNotchCore

/// Where the calendar glance reads from: EventKit in the app, a stand-in
/// everywhere else.
///
/// A protocol for the reason `ShelfTrash` and `ShelfCopier` are seams: a
/// test must never put a Calendars or Reminders prompt on the developer's
/// screen, and must never read their real diary. Everything EventKit is
/// behind these six verbs, and everything it returns is already a value
/// (`CalendarEvent`, `CalendarReminder`) by the time it crosses them.
@MainActor
protocol CalendarSource: AnyObject {
    /// What the app may read. Cheap: a status read, no store, no prompt.
    func access(to entity: CalendarEntity) -> CalendarAccess

    /// Shows the system prompt for `entity`, if macOS still has a question to
    /// ask, and calls back on the main actor once it is answered. Never
    /// called at launch -- only when someone switches the module on, or
    /// presses the pane's "Allow Access…".
    func requestAccess(to entity: CalendarEntity, completion: @escaping @MainActor () -> Void)

    /// The events overlapping `window`, read synchronously.
    func events(in window: DateInterval) -> [CalendarEvent]

    /// Incomplete reminders due before `end`. EventKit only answers this
    /// asynchronously; the callback lands on the main actor.
    func reminders(dueBefore end: Date, completion: @escaping @MainActor ([CalendarReminder]) -> Void)

    /// Calls `onChange` on the main actor whenever the calendar database
    /// changes (`EKEventStoreChanged`). One observer; a second call replaces
    /// the first.
    func startObservingChanges(_ onChange: @escaping @MainActor () -> Void)

    /// Removes the observer and lets go of the store. After this nothing is
    /// registered and no connection to the calendar daemon is held.
    func stop()
}

/// The stand-in a bare `AppDelegate` gets: it reads nothing, prompts for
/// nothing and observes nothing.
///
/// The default for `AppDelegate.calendarSource`, the way the shelf's
/// default Trash is a temporary folder: only `configureForRealLaunch()`
/// hands the delegate EventKit, so a suite that forgets to supply a fake
/// still cannot reach the real calendars.
@MainActor
final class InertCalendarSource: CalendarSource {
    func access(to entity: CalendarEntity) -> CalendarAccess { .notDetermined }
    func requestAccess(to entity: CalendarEntity, completion: @escaping @MainActor () -> Void) {
        completion()
    }
    func events(in window: DateInterval) -> [CalendarEvent] { [] }
    func reminders(dueBefore end: Date, completion: @escaping @MainActor ([CalendarReminder]) -> Void) {
        completion([])
    }
    func startObservingChanges(_ onChange: @escaping @MainActor () -> Void) {}
    func stop() {}
}

/// EventKit, the real source. The only file in the project that imports it.
///
/// **The store is created on first use and dropped on `stop()`.** An
/// `EKEventStore` holds a connection to the calendar daemon; the module is
/// off by default, and a switched-off module must hold nothing. Status reads
/// need no store at all -- `authorizationStatus(for:)` is a class method --
/// so the Settings row can say access is off without opening one.
@MainActor
final class EventKitCalendarSource: CalendarSource {

    private var store: EKEventStore?
    private var observer: NSObjectProtocol?

    private var liveStore: EKEventStore {
        if let store { return store }
        let created = EKEventStore()
        store = created
        return created
    }

    func access(to entity: CalendarEntity) -> CalendarAccess {
        Self.access(EKEventStore.authorizationStatus(for: entity.entityType))
    }

    /// EventKit's statuses in the app's words. Write-only is a refusal for a
    /// glance: it lets an app add events and read none.
    nonisolated static func access(_ status: EKAuthorizationStatus) -> CalendarAccess {
        switch status {
        case .fullAccess:    return .granted
        case .notDetermined: return .notDetermined
        case .restricted:    return .restricted
        case .denied, .writeOnly: return .denied
        @unknown default:    return .denied
        }
    }

    func requestAccess(to entity: CalendarEntity, completion: @escaping @MainActor () -> Void) {
        // The completion-handler forms rather than `async` ones: the handler
        // runs on an arbitrary queue, and hopping to the main actor here keeps
        // the non-`Sendable` store on the actor that owns it.
        let done: @Sendable (Bool, (any Error)?) -> Void = { _, _ in
            Task { @MainActor in completion() }
        }
        switch entity {
        case .events:    liveStore.requestFullAccessToEvents(completion: done)
        case .reminders: liveStore.requestFullAccessToReminders(completion: done)
        }
    }

    func events(in window: DateInterval) -> [CalendarEvent] {
        let store = liveStore
        let predicate = store.predicateForEvents(withStart: window.start, end: window.end, calendars: nil)
        return store.events(matching: predicate)
            .filter { $0.status != .canceled }
            .map(Self.value(of:))
    }

    func reminders(dueBefore end: Date, completion: @escaping @MainActor ([CalendarReminder]) -> Void) {
        let store = liveStore
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil, ending: end, calendars: nil
        )
        // Copied into values on EventKit's queue, before anything crosses
        // back: an `EKReminder` is not `Sendable`, a `CalendarReminder` is.
        store.fetchReminders(matching: predicate) { reminders in
            let values = (reminders ?? []).map(Self.value(of:))
            Task { @MainActor in completion(values) }
        }
    }

    func startObservingChanges(_ onChange: @escaping @MainActor () -> Void) {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        // `queue: .main`, which is what makes `assumeIsolated` sound
        // (ARCHITECTURE.md, Concurrency).
        observer = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: liveStore, queue: .main
        ) { _ in
            MainActor.assumeIsolated { onChange() }
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        store = nil
    }

    // MARK: - Copying out of EventKit

    nonisolated static func value(of event: EKEvent) -> CalendarEvent {
        let start = event.startDate ?? Date.distantPast
        return CalendarEvent(
            // `eventIdentifier` is shared by every occurrence of a repeating
            // event; the start makes each occurrence its own row.
            id: "\(event.calendarItemIdentifier)@\(start.timeIntervalSinceReferenceDate)",
            title: event.title ?? "",
            start: start,
            end: event.endDate ?? start,
            isAllDay: event.isAllDay,
            calendarTitle: event.calendar?.title ?? "",
            color: event.calendar?.cgColor.flatMap(color(of:)) ?? .fallback
        )
    }

    nonisolated static func value(of reminder: EKReminder) -> CalendarReminder {
        let components = reminder.dueDateComponents
        return CalendarReminder(
            id: reminder.calendarItemIdentifier,
            title: reminder.title ?? "",
            due: components.flatMap { Calendar.current.date(from: $0) },
            hasTime: components?.hour != nil,
            isCompleted: reminder.isCompleted
        )
    }

    /// A calendar's colour in sRGB, whatever space EventKit hands it over in.
    nonisolated static func color(of cgColor: CGColor) -> CalendarColor? {
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = cgColor.converted(to: srgb, intent: .defaultIntent, options: nil),
              let c = converted.components, c.count >= 3 else { return nil }
        return CalendarColor(red: Double(c[0]), green: Double(c[1]), blue: Double(c[2]))
    }
}

private extension CalendarEntity {
    var entityType: EKEntityType {
        switch self {
        case .events:    return .event
        case .reminders: return .reminder
        }
    }
}
