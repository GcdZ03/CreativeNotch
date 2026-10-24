import Foundation
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// Fixed dates for the UI-side calendar tests: Wednesday 21 October 2026 in
/// Berlin. The Core suite has its own; test targets cannot share files.
enum CalendarDates {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }()

    static func date(_ hour: Int, _ minute: Int = 0, dayOffset: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 21 + dayOffset, hour: hour, minute: minute))!
    }

    static func event(
        _ title: String, start: Date, end: Date, allDay: Bool = false,
        color: CalendarColor = CalendarColor(red: 0.27, green: 0.55, blue: 1.0),
        calendarTitle: String = "Work"
    ) -> CalendarEvent {
        CalendarEvent(id: title, title: title, start: start, end: end, isAllDay: allDay,
                      calendarTitle: calendarTitle, color: color)
    }

    static func reminder(_ due: Date, hasTime: Bool = true) -> CalendarReminder {
        CalendarReminder(id: UUID().uuidString, title: "r", due: due, hasTime: hasTime, isCompleted: false)
    }
}

/// The controller's whole lifecycle against a fake store: what it reads,
/// when, and -- the point of the module -- what it does not do while nobody
/// is looking at the pane.
@MainActor
struct CalendarControllerTests {

    private final class Published {
        var snapshots: [CalendarSnapshot?] = []
        var last: CalendarSnapshot? { snapshots.last ?? nil }
    }

    /// A controller on a fake source and a pinned clock. The sleeper records
    /// what it was asked for and never returns, so nothing fires by itself;
    /// tests that want the boundary to arrive call `boundaryReached()`.
    private func make(
        _ source: FakeCalendarSource = FakeCalendarSource(),
        now: Date = CalendarDates.date(9)
    ) -> (CalendarController, FakeCalendarSource, Published, SleepLog) {
        let published = Published()
        let log = SleepLog()
        let controller = CalendarController(source: source)
        controller.now = { now }
        controller.calendar = { CalendarDates.calendar }
        controller.sleep = { duration in
            await log.record(duration)
            // Parks until cancelled. Never a fixed real sleep that a test
            // waits out: nothing in these tests awaits it.
            try? await Task.sleep(for: .seconds(86_400 * 365))
        }
        controller.onChange = { published.snapshots.append($0) }
        return (controller, source, published, log)
    }

    // MARK: - Nothing runs that nobody asked for

    @Test func aFreshControllerHasDoneNothing() {
        let (controller, source, published, _) = make()
        #expect(source.isObserving == false)
        #expect(source.eventFetches.isEmpty)
        #expect(source.requests.isEmpty)
        #expect(published.snapshots.isEmpty)
        #expect(controller.boundaryTask == nil)
    }

    /// Enabled at launch (the stored preference applied), the module may
    /// observe and read its grants -- and must not prompt. Nothing is
    /// requested at launch; a prompt belongs to someone switching it on.
    @Test func enablingAtLaunchNeverPrompts() {
        let source = FakeCalendarSource()
        source.accessByEntity = [.events: .notDetermined, .reminders: .notDetermined]
        let (controller, _, published, _) = make(source)

        controller.setEnabled(true, userInitiated: false)

        #expect(source.requests.isEmpty)
        #expect(source.isObserving)
        #expect(published.last?.pane == .needsAccess)
    }

    /// Switched on in Settings: ask, events then reminders, one prompt after
    /// the other -- and only for what is still undecided.
    @Test func switchingOnAsksForWhatIsUndecided() {
        let source = FakeCalendarSource()
        source.accessByEntity = [.events: .notDetermined, .reminders: .notDetermined]
        let (controller, _, _, _) = make(source)

        controller.setEnabled(true, userInitiated: true)
        #expect(source.requests == [.events, .reminders])

        let decided = FakeCalendarSource()
        decided.accessByEntity = [.events: .denied, .reminders: .notDetermined]
        let (other, _, _, _) = make(decided)
        other.setEnabled(true, userInitiated: true)
        #expect(decided.requests == [.reminders], "a refusal is not asked again")
    }

    /// The pane's button asks too, and asking with nothing undecided asks
    /// nothing: macOS would answer from the stored refusal without a prompt.
    @Test func thePaneButtonAsksOnlyWhenThereIsAQuestion() {
        let source = FakeCalendarSource()
        source.accessByEntity = [.events: .notDetermined, .reminders: .denied]
        let (controller, _, _, _) = make(source)
        controller.setEnabled(true, userInitiated: false)

        controller.requestAccess()
        #expect(source.requests == [.events])
        controller.requestAccess()
        #expect(source.requests == [.events], "granted by then: nothing left to ask")
    }

    /// Enabled but with the pane closed, nothing is read: no events, no
    /// reminders, no boundary one-shot.
    @Test func nothingIsReadWhileThePaneIsClosed() {
        let (controller, source, _, _) = make()
        controller.setEnabled(true, userInitiated: false)

        #expect(source.eventFetches.isEmpty)
        #expect(source.reminderFetches.isEmpty)
        #expect(controller.boundaryTask == nil)

        source.postChange()
        #expect(source.eventFetches.isEmpty, "a database change while closed waits for the next open")
    }

    // MARK: - Refreshing

    @Test func openingThePaneReadsTodayAndTomorrow() {
        let source = FakeCalendarSource()
        source.events = [CalendarDates.event("Standup", start: CalendarDates.date(9, 30), end: CalendarDates.date(9, 45))]
        source.reminders = [CalendarDates.reminder(CalendarDates.date(8))]
        let (controller, _, published, _) = make(source)
        controller.setEnabled(true, userInitiated: false)

        controller.setPaneVisible(true)

        #expect(source.eventFetches == [DateInterval(start: CalendarDates.date(0), end: CalendarDates.date(0, dayOffset: 2))])
        #expect(source.reminderFetches == [CalendarDates.date(0, dayOffset: 1)])
        #expect(published.last?.events.map(\.title) == ["Standup"])
        #expect(published.last?.reminders.count == 1)
        #expect(published.last?.refreshedAt == CalendarDates.date(9))
    }

    /// While the pane is on screen, a change in Calendar shows at once.
    @Test func aDatabaseChangeWhileOpenRefreshes() {
        let (controller, source, published, _) = make()
        controller.setEnabled(true, userInitiated: false)
        controller.setPaneVisible(true)
        let reads = source.eventFetches.count

        source.events = [CalendarDates.event("New", start: CalendarDates.date(11), end: CalendarDates.date(12))]
        source.postChange()

        #expect(source.eventFetches.count == reads + 1)
        #expect(published.last?.events.map(\.title) == ["New"])
    }

    /// A refused grant is not read around: no event query is made at all.
    @Test func aRefusedGrantReadsNothing() {
        let source = FakeCalendarSource()
        source.accessByEntity = [.events: .denied, .reminders: .denied]
        let (controller, _, published, _) = make(source)
        controller.setEnabled(true, userInitiated: false)
        controller.setPaneVisible(true)

        #expect(source.eventFetches.isEmpty)
        #expect(source.reminderFetches.isEmpty)
        #expect(published.last?.pane == .denied)
    }

    /// The reminder line keeps its last count while a fresh one is fetched,
    /// so it does not blink to zero on every refresh.
    @Test func remindersCarryOverUntilTheNewOnesArrive() {
        let source = FakeCalendarSource()
        source.reminders = [CalendarDates.reminder(CalendarDates.date(8))]
        let (controller, _, published, _) = make(source)
        controller.setEnabled(true, userInitiated: false)
        controller.setPaneVisible(true)
        #expect(published.last?.reminders.count == 1)

        source.answersRemindersImmediately = false
        source.reminders = []
        source.postChange()
        #expect(published.last?.reminders.count == 1, "still the old count while fetching")

        source.answerReminders()
        #expect(published.last?.reminders.isEmpty == true)
    }

    /// A late answer for a module switched off since is dropped, not drawn.
    @Test func aLateReminderAnswerAfterSwitchingOffIsDropped() {
        let source = FakeCalendarSource()
        source.answersRemindersImmediately = false
        source.reminders = [CalendarDates.reminder(CalendarDates.date(8))]
        let (controller, _, published, _) = make(source)
        controller.setEnabled(true, userInitiated: false)
        controller.setPaneVisible(true)

        controller.setEnabled(false, userInitiated: false)
        source.answerReminders()

        #expect(published.last == nil as CalendarSnapshot?)
    }

    // MARK: - The one-shot

    /// While the pane is open, one task sleeps until the next boundary --
    /// here 09:01, when the standup's row goes from "in 30 min" to
    /// "in 29 min".
    @Test func theBoundaryIsScheduledForTheNextEventEdge() async {
        let source = FakeCalendarSource()
        source.events = [CalendarDates.event("Standup", start: CalendarDates.date(9, 30), end: CalendarDates.date(9, 45))]
        let (controller, _, _, log) = make(source)
        controller.setEnabled(true, userInitiated: false)
        controller.setPaneVisible(true)

        #expect(controller.scheduledBoundary == CalendarDates.date(9, 1))
        #expect(controller.boundaryTask != nil)
        await log.waitForRequests(1)
        #expect(await log.requests == [.seconds(60)])
    }

    /// One at a time: a refresh that moves the boundary replaces the pending
    /// one-shot rather than adding a second, and one that leaves it where it
    /// was keeps the task already sleeping towards it.
    @Test func aRefreshKeepsExactlyOneBoundary() {
        let source = FakeCalendarSource()
        source.events = [CalendarDates.event("Lunch", start: CalendarDates.date(12), end: CalendarDates.date(13))]
        let (controller, _, _, _) = make(source)
        controller.setEnabled(true, userInitiated: false)
        controller.setPaneVisible(true)
        let first = controller.boundaryTask
        // Lunch at 12:00 starts counting down an hour before.
        #expect(controller.scheduledBoundary == CalendarDates.date(11))

        source.postChange()
        #expect(controller.boundaryTask == first, "same boundary, same task")
        #expect(first?.isCancelled == false)

        source.events.append(CalendarDates.event("Call", start: CalendarDates.date(9, 20), end: CalendarDates.date(9, 40)))
        source.postChange()
        #expect(first?.isCancelled == true)
        #expect(controller.boundaryTask != nil)
        // The call, 20 minutes off, counts down: "in 19 min" at 09:01.
        #expect(controller.scheduledBoundary == CalendarDates.date(9, 1))
    }

    /// Reaching the boundary refreshes, and the refresh schedules the next.
    @Test func reachingTheBoundaryRefreshes() {
        let (controller, source, published, _) = make()
        controller.setEnabled(true, userInitiated: false)
        controller.setPaneVisible(true)
        let reads = source.eventFetches.count
        let count = published.snapshots.count

        controller.boundaryReached()

        #expect(source.eventFetches.count == reads + 1)
        #expect(published.snapshots.count > count)
        #expect(controller.boundaryTask != nil)
    }

    /// Closing the pane cancels the one-shot: nothing is scheduled while
    /// nobody is looking.
    @Test func closingThePaneCancelsTheBoundary() {
        let (controller, _, _, _) = make()
        controller.setEnabled(true, userInitiated: false)
        controller.setPaneVisible(true)
        let task = controller.boundaryTask

        controller.setPaneVisible(false)

        #expect(task?.isCancelled == true)
        #expect(controller.boundaryTask == nil)
        #expect(controller.scheduledBoundary == nil)
    }

    // MARK: - Switching off stops everything

    @Test func switchingOffStopsEverythingItRuns() {
        let (controller, source, published, _) = make()
        controller.setEnabled(true, userInitiated: false)
        controller.setPaneVisible(true)
        let task = controller.boundaryTask

        controller.setEnabled(false, userInitiated: false)

        #expect(source.isObserving == false)
        #expect(source.stopCount == 1)
        #expect(task?.isCancelled == true)
        #expect(controller.boundaryTask == nil)
        #expect(published.last == nil as CalendarSnapshot?, "the glance goes with the module")

        // And stays quiet: a change notification that slipped through, or
        // the pane reopening, reads nothing.
        let reads = source.eventFetches.count
        source.postChange()
        controller.setPaneVisible(false)
        controller.setPaneVisible(true)
        #expect(source.eventFetches.count == reads)
    }

    /// Settings shown: the grants are read again, so a refusal changed in
    /// System Settings since shows up without reopening anything.
    @Test func refreshingAccessReadsTheGrantsAgain() {
        let (controller, source, published, _) = make()
        controller.setEnabled(true, userInitiated: false)
        #expect(published.last?.pane == .glance(showsEvents: true, showsReminders: true))

        source.accessByEntity = [.events: .denied, .reminders: .denied]
        controller.refreshAccess()

        #expect(published.last?.pane == .denied)
        #expect(source.eventFetches.isEmpty, "reading the grants is not reading the calendar")
    }
}

/// What the controller asked to sleep for, recorded off the main actor's
/// back so a test can await it.
actor SleepLog {
    private(set) var requests: [Duration] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func record(_ duration: Duration) {
        requests.append(duration)
        let ready = waiters.filter { requests.count >= $0.0 }
        waiters.removeAll { requests.count >= $0.0 }
        for (_, continuation) in ready { continuation.resume() }
    }

    /// Returns once `count` sleeps have been asked for.
    func waitForRequests(_ count: Int) async {
        if requests.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
}
