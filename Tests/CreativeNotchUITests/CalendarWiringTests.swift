import AppKit
import Foundation
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// The calendar module through the delegate: the switchboard leg, the funnel
/// that tells it the pane is open, the pane's verbs, and the seams that keep
/// a test run away from the real calendar.
@MainActor
struct CalendarWiringTests {

    /// A delegate on a fake calendar, with the usual real-world seams off.
    /// `calendarSource` is set before `install`, which hands it to the
    /// controller -- the order `shelfTrash` already needs.
    private func makeDelegate(
        _ source: FakeCalendarSource = FakeCalendarSource(),
        defaults: UserDefaults = TestDefaults.isolated("calendar")
    ) -> (AppDelegate, FakeCalendarSource) {
        let delegate = AppDelegate()
        delegate.shelfTrash = TestTrash.shelf
        delegate.preferencesDefaults = defaults
        delegate.growthDelay = .zero
        delegate.playChime = { _ in }
        delegate.calendarSource = source
        delegate.install(metrics: NotchedDelegate.metrics)
        delegate.clipboard?.poller.scheduleTimer = { _, _ in nil }
        delegate.clipboard?.poller.cancelTimer = { _ in }
        delegate.media?.supervisor.startHelper = {}
        delegate.media?.supervisor.stopHelper = {}
        // No real clock: a fixed Wednesday 09:00 in Berlin, and a one-shot
        // that parks until cancelled without ever reading the time.
        delegate.calendar?.now = { CalendarDates.date(9) }
        delegate.calendar?.calendar = { CalendarDates.calendar }
        delegate.calendar?.sleep = { _ in
            // A stream nothing ever yields to: iterating it suspends until
            // the task is cancelled, then ends. No timer is involved.
            let neverYields = AsyncStream<Never> { _ in }
            for await _ in neverYields {}
        }
        return (delegate, source)
    }

    // MARK: - Off by default, and asking only when asked

    /// A fresh install leaves the calendar off: no observer, no tab, nothing
    /// published, no prompt.
    @Test func aFreshInstallLeavesTheCalendarOff() {
        let (delegate, source) = makeDelegate()
        delegate.switchboard.apply()

        #expect(delegate.state.preferences.calendar == false)
        #expect(source.isObserving == false)
        #expect(source.requests.isEmpty)
        #expect(delegate.state.calendar == nil)
        #expect(!TabVisibility.visible(enabled: delegate.state.preferences, hasBattery: true).contains(.calendar))
    }

    /// Switched on in Settings: the prompt comes now, because someone asked.
    @Test func switchingOnInSettingsAsksForAccess() {
        let source = FakeCalendarSource()
        source.accessByEntity = [.events: .notDetermined, .reminders: .notDetermined]
        let (delegate, _) = makeDelegate(source)
        delegate.switchboard.apply()

        delegate.switchboard.setEnabled(true, for: .calendar, persist: true)

        #expect(source.requests == [.events, .reminders])
        #expect(source.isObserving)
        #expect(delegate.state.calendar?.pane == .glance(showsEvents: true, showsReminders: true))
    }

    /// A stored "on" applied at launch asks nothing, even with access still
    /// undecided: nothing is requested at launch. The pane offers the button.
    @Test func aStoredOnAtLaunchDoesNotPrompt() {
        let source = FakeCalendarSource()
        source.accessByEntity = [.events: .notDetermined, .reminders: .notDetermined]
        let defaults = TestDefaults.isolated("calendar-launch")
        PreferencesStore(defaults: defaults).setEnabled(true, for: .calendar)
        let (delegate, _) = makeDelegate(source, defaults: defaults)

        delegate.switchboard.apply()

        #expect(delegate.state.preferences.calendar)
        #expect(source.requests.isEmpty)
        #expect(delegate.state.calendar?.pane == .needsAccess)

        delegate.state.onRequestCalendarAccess?()
        #expect(source.requests == [.events, .reminders], "the pane's button is wired to ask")
    }

    // MARK: - Reading only while the pane is open

    /// The funnel tells the controller when its pane opens and closes: open
    /// reads, any other state cancels the one-shot.
    @Test func openingThePaneReadsAndLeavingItCancelsTheBoundary() {
        let source = FakeCalendarSource()
        source.events = [CalendarDates.event("Standup", start: CalendarDates.date(9, 10), end: CalendarDates.date(9, 20))]
        let (delegate, _) = makeDelegate(source)
        delegate.switchboard.apply()
        delegate.switchboard.setEnabled(true, for: .calendar, persist: true)
        #expect(source.eventFetches.isEmpty, "switched on, but the pane is closed")

        delegate.state.transition(to: .open(.calendar), openedBy: .tap)
        #expect(source.eventFetches.count == 1)
        #expect(delegate.state.calendar?.events.map(\.title) == ["Standup"])
        #expect(delegate.calendar?.boundaryTask != nil)
        // "in 10 min" at the pinned 09:00 next reads "in 9 min" at 09:01.
        #expect(delegate.calendar?.scheduledBoundary == CalendarDates.date(9, 1))

        delegate.state.transition(to: .open(.shelf))
        #expect(delegate.calendar?.boundaryTask == nil)

        delegate.state.transition(to: .closed)
        source.postChange()
        #expect(source.eventFetches.count == 1, "closed: a database change reads nothing")
    }

    // MARK: - Switching off

    /// Off stops everything and takes the pane away, moving an open panel
    /// off the tab that just disappeared.
    @Test func switchingOffStopsItAndRetargetsTheTab() {
        let (delegate, source) = makeDelegate()
        delegate.switchboard.apply()
        delegate.switchboard.setEnabled(true, for: .calendar, persist: true)
        delegate.state.transition(to: .open(.calendar), openedBy: .tap)

        delegate.switchboard.setEnabled(false, for: .calendar, persist: true)

        #expect(source.isObserving == false)
        #expect(source.stopCount >= 1)
        #expect(delegate.calendar?.boundaryTask == nil)
        #expect(delegate.state.calendar == nil)
        #expect(delegate.state.state == .open(.shelf))
        #expect(PreferencesStore(defaults: delegate.preferencesDefaults).load().calendar == false)
    }

    @Test func quittingStopsTheCalendar() {
        let (delegate, source) = makeDelegate()
        delegate.switchboard.apply()
        delegate.switchboard.setEnabled(true, for: .calendar, persist: true)

        delegate.switchboard.stopAll()

        #expect(source.isObserving == false)
        #expect(delegate.state.calendar == nil)
    }

    // MARK: - The pane's verbs and the seams

    /// "Open Privacy Settings" and "Open Calendar" go through the delegate's
    /// opener, which a test replaces -- no app opens during a test run.
    @Test func thePaneVerbsOpenThroughTheSeam() {
        let (delegate, _) = makeDelegate()
        var opened: [URL] = []
        delegate.openExternalURL = { opened.append($0) }

        delegate.state.onOpenCalendarPrivacySettings?()
        delegate.state.onOpenCalendarApp?()

        #expect(opened == [AppDelegate.calendarPrivacyURL, AppDelegate.calendarAppURL])
        #expect(AppDelegate.calendarPrivacyURL.absoluteString.contains("Privacy_Calendars"))
    }

    /// A bare delegate reaches no real calendar and opens nothing: the
    /// source is the inert stand-in until `configureForRealLaunch()`.
    @Test func aBareDelegateIsSandboxedFromTheCalendar() {
        let delegate = AppDelegate()
        #expect(delegate.calendarSource is InertCalendarSource)
        #expect(!(delegate.calendarSource is EventKitCalendarSource))

        delegate.configureForRealLaunch()
        #expect(delegate.calendarSource is EventKitCalendarSource)
    }

    /// Settings shown re-reads the grants, so the row's warning follows a
    /// refusal made in System Settings.
    @Test func settingsWarnsWhenAccessIsRefused() {
        let source = FakeCalendarSource()
        let (delegate, _) = makeDelegate(source)
        delegate.switchboard.apply()
        delegate.switchboard.setEnabled(true, for: .calendar, persist: true)
        let controller = PreferencesController(
            switchboard: delegate.switchboard,
            state: delegate.state,
            // An uninstalled path: ineligible, so it reads nothing.
            launchAtLogin: LaunchAtLoginController(
                bundlePath: "/tmp/NotInstalled.app",
                installDirectories: ["/Applications"],
                readStatus: { 0 }, register: {}, unregister: {}
            ),
            presenter: { _ in }
        )
        #expect(PreferencesView.warning(for: .calendar, controller: controller) == nil)

        source.accessByEntity = [.events: .denied, .reminders: .denied]
        controller.show()

        let warning = PreferencesView.warning(for: .calendar, controller: controller)
        #expect(warning?.contains("Privacy & Security") == true, "a refusal can be undone there")
    }

    /// Restricted by a profile or Screen Time, the warning says so and does
    /// not send anyone to a setting that cannot change it.
    @Test func settingsExplainsARestrictedGrant() {
        let source = FakeCalendarSource()
        let (delegate, _) = makeDelegate(source)
        delegate.switchboard.apply()
        delegate.switchboard.setEnabled(true, for: .calendar, persist: true)
        let controller = PreferencesController(
            switchboard: delegate.switchboard,
            state: delegate.state,
            launchAtLogin: LaunchAtLoginController(
                bundlePath: "/tmp/NotInstalled.app",
                installDirectories: ["/Applications"],
                readStatus: { 0 }, register: {}, unregister: {}
            ),
            presenter: { _ in }
        )

        source.accessByEntity = [.events: .restricted, .reminders: .restricted]
        controller.show()

        #expect(delegate.state.calendar?.pane == .restricted)
        let warning = PreferencesView.warning(for: .calendar, controller: controller)
        #expect(warning?.contains("restricted") == true)
        #expect(warning?.contains("Privacy & Security") == false)
        #expect(warning?.contains("Turn it on") == false)
    }
}
