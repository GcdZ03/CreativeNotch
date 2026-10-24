import Foundation
import CreativeNotchCore

/// Reads the calendar for the glance -- and, the point of the design, reads
/// nothing while the pane is closed.
///
/// **What runs, and when.** Switched on, the controller registers one
/// `EKEventStoreChanged` observer (a notification: it costs nothing until
/// Calendar changes) and reads the two grants, which is a status read rather
/// than a query. That is all. The calendar itself is queried only when the
/// pane is opened, when the database changes *while* the pane is open, and
/// when a single one-shot reaches the next instant the glance would read
/// differently (`CalendarGlance.nextBoundary`) -- again only while the pane
/// is open. A change posted while it is closed is not acted on: opening the
/// pane reads afresh anyway, so acting on it would be a query nobody sees.
///
/// So there is no polling and no repeating timer: the one-shot is the
/// timer's shape (ARCHITECTURE.md, "Allowed, with the timer as the
/// precedent"), scheduled to a known instant, one at a time, and cancelled
/// the moment the pane goes.
///
/// It is not on the `SystemActivity` axis because there is nothing to
/// suspend: the pane cannot be open on a locked or sleeping screen, so the
/// one-shot is already gone, and the observer costs nothing idle -- the
/// power module's reasoning.
///
/// **Prompts.** `setEnabled(_:userInitiated:)` asks for access only when the
/// person switched the module on in Settings, never when the stored
/// preference is applied at launch; the pane's "Allow Access…" is the other
/// way to ask. Nothing is requested at launch.
@MainActor
final class CalendarController {

    /// The glance, or `nil` when the module is off. Wired to `AppState`.
    var onChange: ((CalendarSnapshot?) -> Void)?

    /// Overridable so tests pin the instant and the time zone, the way the
    /// delegate's `now` is.
    var now: () -> Date = { Date() }
    var calendar: () -> Calendar = { Calendar.autoupdatingCurrent }

    /// How the one-shot waits. Overridable so a test records the delay and
    /// decides whether it ever returns, rather than waiting out a real one.
    var sleep: @Sendable (Duration) async -> Void = { duration in
        try? await Task.sleep(for: duration)
    }

    private let source: CalendarSource

    private(set) var isEnabled = false
    private(set) var isPaneVisible = false

    /// The one pending wake, or `nil`. Exposed so tests can prove there is
    /// never more than one, and none while the pane is closed.
    private(set) var boundaryTask: Task<Void, Never>?

    /// The instant `boundaryTask` sleeps until.
    private(set) var scheduledBoundary: Date?

    /// What was last published, so a refresh can carry the reminders over
    /// while their asynchronous fetch is in flight.
    private(set) var snapshot: CalendarSnapshot?

    /// Bumped by every refresh and by `stop`, so a reminder answer that
    /// arrives after either belongs to a read nobody is waiting for any more
    /// and is dropped.
    private var generation = 0

    init(source: CalendarSource) {
        self.source = source
    }

    // MARK: - Lifecycle

    /// Starts or stops the module. `userInitiated` is true only for the
    /// Settings switch, which is what earns a permission prompt.
    func setEnabled(_ enabled: Bool, userInitiated: Bool) {
        if !enabled {
            stop()
            return
        }
        if !isEnabled {
            isEnabled = true
            source.startObservingChanges { [weak self] in self?.storeDidChange() }
        }
        if isPaneVisible { refresh() } else { refreshAccess() }
        if userInitiated { requestAccess() }
    }

    /// Stops everything the module runs: the observer, the store's
    /// connection, the one-shot -- and withdraws the glance, so nothing it
    /// read stays on screen or in memory after the switch goes off.
    func stop() {
        let wasRunning = isEnabled || snapshot != nil
        isEnabled = false
        generation &+= 1
        cancelBoundary()
        source.stop()
        snapshot = nil
        if wasRunning { onChange?(nil) }
    }

    /// Whether the calendar pane is on screen. Fed from the `AppState`
    /// funnel, like the camera's tab visibility.
    func setPaneVisible(_ visible: Bool) {
        guard visible != isPaneVisible else { return }
        isPaneVisible = visible
        if visible {
            refresh()
        } else {
            cancelBoundary()
        }
    }

    // MARK: - Access

    /// Asks for whatever is still undecided, events first, one prompt after
    /// the other, then reads. A refused grant is not asked again: macOS
    /// answers from the stored decision without a prompt, so the pane offers
    /// System Settings instead.
    func requestAccess() {
        guard isEnabled else { return }
        let undecided = CalendarEntity.allCases.filter { source.access(to: $0).isRequestable }
        guard !undecided.isEmpty else { return }
        request(undecided[...])
    }

    private func request(_ remaining: ArraySlice<CalendarEntity>) {
        guard let entity = remaining.first else {
            if isPaneVisible { refresh() } else { refreshAccess() }
            return
        }
        source.requestAccess(to: entity) { [weak self] in
            guard let self, self.isEnabled else { return }
            self.request(remaining.dropFirst())
        }
    }

    /// Re-reads the two grants without querying the calendar, for Settings
    /// and for a pane that is not open. Keeps whatever was read before.
    func refreshAccess() {
        guard isEnabled else { return }
        var next = snapshot ?? CalendarSnapshot(
            eventsAccess: .notDetermined, remindersAccess: .notDetermined, refreshedAt: now()
        )
        next.eventsAccess = source.access(to: .events)
        next.remindersAccess = source.access(to: .reminders)
        if next.eventsAccess != .granted { next.events = [] }
        if next.remindersAccess != .granted { next.reminders = [] }
        next.refreshedAt = now()
        publish(next)
    }

    // MARK: - Reading

    /// Reads today and tomorrow and republishes, then schedules the next
    /// boundary. Only what is granted is queried.
    func refresh() {
        guard isEnabled else { return }
        generation &+= 1
        let generation = self.generation
        let instant = now()
        let calendar = calendar()
        let eventsAccess = source.access(to: .events)
        let remindersAccess = source.access(to: .reminders)
        let window = CalendarGlance.fetchWindow(now: instant, calendar: calendar)

        let events = eventsAccess == .granted ? source.events(in: window) : []
        // The last count stays up while the new one is fetched, so the line
        // does not blink to "No reminders" on every refresh.
        let carried = remindersAccess == .granted ? (snapshot?.reminders ?? []) : []
        publish(CalendarSnapshot(
            eventsAccess: eventsAccess,
            remindersAccess: remindersAccess,
            events: events,
            reminders: carried,
            refreshedAt: instant
        ))
        scheduleBoundary()

        guard remindersAccess == .granted else { return }
        let endOfToday = calendar.date(byAdding: .day, value: 1, to: window.start) ?? window.end
        source.reminders(dueBefore: endOfToday) { [weak self] reminders in
            guard let self, self.isEnabled, generation == self.generation,
                  var next = self.snapshot else { return }
            next.reminders = reminders
            self.publish(next)
            // A timed reminder may fall due before the boundary chosen
            // without it.
            self.scheduleBoundary()
        }
    }

    /// The one-shot's landing: read again, which schedules the next.
    /// Internal so a test can arrive at the boundary without waiting for it.
    func boundaryReached() {
        // The task that called this has done its one sleep. Forgotten first,
        // so the refresh below schedules a fresh one even if the clock reads
        // a hair short of the boundary and picks the same instant again.
        // Cancelling it is harmless: it is finishing.
        cancelBoundary()
        refresh()
    }

    private func storeDidChange() {
        // Closed, the next open reads afresh anyway.
        guard isEnabled, isPaneVisible else { return }
        refresh()
    }

    private func publish(_ next: CalendarSnapshot) {
        snapshot = next
        onChange?(next)
    }

    // MARK: - The one-shot

    /// Points the one-shot at the next boundary. A refresh that leaves the
    /// boundary where it was keeps the task already sleeping towards it,
    /// rather than cancelling one wake to schedule the same wake again.
    private func scheduleBoundary() {
        guard isEnabled, isPaneVisible, let snapshot else {
            cancelBoundary()
            return
        }
        let instant = now()
        let boundary = CalendarGlance.nextBoundary(
            after: instant, events: snapshot.events, reminders: snapshot.reminders, calendar: calendar()
        )
        if boundary == scheduledBoundary, boundaryTask != nil { return }
        cancelBoundary()
        scheduledBoundary = boundary
        let delay = Duration.milliseconds(Int64((boundary.timeIntervalSince(instant) * 1000).rounded(.up)))
        let sleep = self.sleep
        boundaryTask = Task { [weak self] in
            await sleep(delay)
            guard !Task.isCancelled else { return }
            self?.boundaryReached()
        }
    }

    private func cancelBoundary() {
        boundaryTask?.cancel()
        boundaryTask = nil
        scheduledBoundary = nil
    }
}
