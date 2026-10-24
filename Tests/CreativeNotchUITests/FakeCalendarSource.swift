import Foundation
import CreativeNotchCore
@testable import CreativeNotchUI

/// A calendar the test writes, standing in for EventKit.
///
/// Records every question asked of it, so a test can prove what the
/// controller did *not* do -- read events while the pane was hidden, prompt
/// at launch -- as well as what it did. Reminders are answered when the test
/// says so (`answerReminders`), the way EventKit answers them: later.
@MainActor
final class FakeCalendarSource: CalendarSource {
    var accessByEntity: [CalendarEntity: CalendarAccess] = [.events: .granted, .reminders: .granted]
    /// What a request turns `.notDetermined` into.
    var grantOnRequest = true

    var events: [CalendarEvent] = []
    var reminders: [CalendarReminder] = []

    private(set) var requests: [CalendarEntity] = []
    private(set) var eventFetches: [DateInterval] = []
    private(set) var reminderFetches: [Date] = []
    private(set) var isObserving = false
    private(set) var stopCount = 0
    private var onChange: (@MainActor () -> Void)?
    private var pendingReminderAnswers: [@MainActor ([CalendarReminder]) -> Void] = []

    /// Whether reminder fetches answer at once (the default) or wait for
    /// `answerReminders()`.
    var answersRemindersImmediately = true

    func access(to entity: CalendarEntity) -> CalendarAccess {
        accessByEntity[entity] ?? .notDetermined
    }

    func requestAccess(to entity: CalendarEntity, completion: @escaping @MainActor () -> Void) {
        requests.append(entity)
        if accessByEntity[entity] == .notDetermined {
            accessByEntity[entity] = grantOnRequest ? .granted : .denied
        }
        completion()
    }

    func events(in window: DateInterval) -> [CalendarEvent] {
        eventFetches.append(window)
        return events
    }

    func reminders(dueBefore end: Date, completion: @escaping @MainActor ([CalendarReminder]) -> Void) {
        reminderFetches.append(end)
        if answersRemindersImmediately {
            completion(reminders)
        } else {
            pendingReminderAnswers.append(completion)
        }
    }

    /// Answers every reminder fetch still waiting, with `reminders`.
    func answerReminders() {
        let answers = pendingReminderAnswers
        pendingReminderAnswers = []
        for answer in answers { answer(reminders) }
    }

    func startObservingChanges(_ onChange: @escaping @MainActor () -> Void) {
        isObserving = true
        self.onChange = onChange
    }

    func stop() {
        isObserving = false
        onChange = nil
        stopCount += 1
    }

    /// What `EKEventStoreChanged` would do.
    func postChange() {
        onChange?()
    }
}
