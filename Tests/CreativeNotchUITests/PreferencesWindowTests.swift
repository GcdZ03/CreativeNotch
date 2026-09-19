import AppKit
import Foundation
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// The settings surface.
///
/// Driven through a spy presenter so no test ever creates or presents a real
/// `NSWindow` -- the same split `OnboardingController` established.
@MainActor
struct PreferencesWindowTests {

    private func makeDelegate() -> AppDelegate {
        let delegate = AppDelegate()
        delegate.preferencesDefaults = TestDefaults.isolated("prefs-window")
        delegate.growthDelay = .zero
        delegate.shelfDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CreativeNotchPrefsWindow-\(UUID().uuidString)")
        delegate.playChime = {}
        delegate.install(metrics: NotchedDelegate.metrics)
        // The indicator would otherwise read the developer's real
        // microphone and camera, so the suite would pass or fail
        // depending on whether they happened to be on a call.
        delegate.capture?.observer.readCurrentUse = { .none }
        delegate.clipboard?.poller.scheduleTimer = { _, _ in nil }
        delegate.clipboard?.poller.cancelTimer = { _ in }
        delegate.media?.supervisor.startHelper = {}
        delegate.media?.supervisor.stopHelper = {}
        return delegate
    }

    private func makeController(_ delegate: AppDelegate) -> PreferencesController {
        PreferencesController(
            switchboard: delegate.switchboard,
            state: delegate.state,
            launchAtLogin: delegate.launchAtLogin
        )
    }

    // MARK: - The write path

    /// The window writes through the switchboard and nowhere else: one
    /// direction, one source of truth, and no second path that could apply a
    /// change without persisting it or persist one without applying it.
    @Test func flippingASwitchStopsTheSubsystem() throws {
        let delegate = makeDelegate()
        let clipboard = try #require(delegate.clipboard)
        delegate.startSubsystems()
        #expect(clipboard.poller.scheduledInterval != nil)

        makeController(delegate).setEnabled(false, for: .clipboard)

        #expect(clipboard.poller.scheduledInterval == nil)
        delegate.activity.stop()
    }

    /// And it persists, so the choice survives a relaunch. Asserted through
    /// the store rather than the in-memory value, which would pass against a
    /// switchboard that applied without saving.
    @Test func flippingASwitchIsRemembered() {
        let delegate = makeDelegate()
        delegate.startSubsystems()

        makeController(delegate).setEnabled(false, for: .clipboard)

        #expect(delegate.preferencesStore.load().clipboard == false)
        delegate.activity.stop()
    }

    /// The switch reflects what is actually set, so reopening the window does
    /// not show stale state.
    @Test func aSwitchReadsBackWhatWasSet() {
        let delegate = makeDelegate()
        let controller = makeController(delegate)
        #expect(controller.isEnabled(.timer))

        controller.setEnabled(false, for: .timer)

        #expect(controller.isEnabled(.timer) == false)
    }

    // MARK: - The rows

    /// Every module gets a switch, or one ships unreachable.
    @Test func everyModuleHasASwitch() {
        #expect(Set(PreferencesView.rows.map(\.module)) == Set(ModuleID.allCases))
        #expect(PreferencesView.rows.count == ModuleID.allCases.count)
    }

    /// A grouped form with an empty group is a heading over nothing, and a
    /// row without a symbol is a blank tile.
    @Test func everySectionIsNonEmptyAndEveryRowHasASymbol() {
        for section in PreferencesSection.allCases {
            #expect(PreferencesView.rows.contains { $0.section == section }, "\(section) has no rows")
        }
        #expect(PreferencesView.rows.allSatisfy { !$0.symbolName.isEmpty })
        #expect(Set(PreferencesView.rows.map(\.symbolName)).count == PreferencesView.rows.count)
    }

    /// The three notes the spec requires are copy with a job, not decoration:
    /// the shelf's toggle saves no power, and transport's only means "not
    /// loaded" when it was off at launch.
    @Test func theRowsThatNeedAnHonestyNoteCarryOne() throws {
        let shelf = try #require(PreferencesView.rows.first { $0.module == .shelf })
        #expect(shelf.detail.contains("does not save battery"))

        let transport = try #require(PreferencesView.rows.first { $0.module == .mediaControls })
        #expect(transport.detail.contains("until the next launch"))
    }

    // MARK: - Conditional warnings

    /// Shown unconditionally, a warning trains people to ignore it.
    @Test func theTimerRowWarnsOnlyWhileACountdownIsRunning() {
        let delegate = makeDelegate()
        let controller = makeController(delegate)
        #expect(PreferencesView.warning(for: .timer, controller: controller) == nil)

        delegate.state.countdown = Countdown(duration: 60, startingAt: Date())

        let warning = PreferencesView.warning(for: .timer, controller: controller)
        #expect(warning?.contains("finish and chime") == true)
    }

    /// The honesty rule with teeth. `CGEventTapCreate` genuinely fails without
    /// Accessibility, and `MediaKeyMonitor.start()` records that as
    /// `isRunning = token != nil` with no retry -- so a switch reading "on"
    /// over a dead subsystem is the exact inversion of the failure this whole
    /// module exists to prevent. The warning tracks the PERMISSION, never the
    /// preference.
    @Test func theHudRowReportsThePermissionNotThePreference() {
        let delegate = makeDelegate()
        let controller = makeController(delegate)

        let warning = PreferencesView.warning(for: .hud, controller: controller)
        if Permissions.isAccessibilityTrusted {
            #expect(warning == nil)
        } else {
            #expect(warning?.contains("Accessibility is not granted") == true)
        }

        // Switching the module off must not change what the warning says: it
        // is about the grant, not about the toggle.
        controller.setEnabled(false, for: .hud)
        #expect(PreferencesView.warning(for: .hud, controller: controller) == warning)
    }

    @Test func noOtherRowCarriesAWarning() {
        let delegate = makeDelegate()
        let controller = makeController(delegate)
        for module in [ModuleID.shelf, .clipboard, .mediaMetadata, .mediaControls, .power] {
            #expect(PreferencesView.warning(for: module, controller: controller) == nil)
        }
    }

    // MARK: - Launch at login

    /// It is deliberately **not** a module: the system owns the state, so
    /// there is no stored `Bool` and nothing to stop. `rows` stays a list of
    /// modules, which is what keeps `everyModuleHasASwitch` meaningful.
    @Test func launchAtLoginIsNotAModuleRow() {
        #expect(ModuleID.allCases.count == 10)
        #expect(PreferencesView.rows.allSatisfy { $0.title != "Open at login" })
        #expect(PreferencesView.rows.count == ModuleID.allCases.count)
    }

    /// The real controller respects the path it is running from.
    ///
    /// The suite runs from a build directory, never `/Applications`, so it
    /// must be in the state that touches nothing at all -- if this ever
    /// reports otherwise, a test run has been repointing the developer's own
    /// login item, which is the failure the whole eligibility rule exists to
    /// prevent and the one that would never announce itself.
    ///
    /// **This deliberately does not assert that the window and the app share
    /// one controller.** An `===` check here passed against a `showPreferences()`
    /// mutated to build a fresh controller every time, because the test
    /// supplies the controller it then reads back. Rather than prop it up
    /// with a source scan, the claim is dropped: sharing is not load-bearing.
    /// Construction reads nothing, and `refresh()` reads the system on every
    /// appearance, so a second controller would behave identically.
    @Test func theRealControllerRefusesAnUninstalledCopy() {
        let delegate = makeDelegate()

        guard case .unavailable = delegate.launchAtLogin.state else {
            Issue.record("a test-run bundle was treated as installed: \(delegate.launchAtLogin.state)")
            return
        }
    }

    /// And the row it draws cannot be operated in that state -- asserted
    /// through the controller, because a `.disabled` modifier is not
    /// reachable from a test.
    @Test func anUninstalledCopyCannotBeSwitchedOn() {
        let delegate = makeDelegate()
        let before = delegate.launchAtLogin.state

        delegate.launchAtLogin.setEnabled(true)

        #expect(delegate.launchAtLogin.state == before)
        guard case .unavailable = delegate.launchAtLogin.state else {
            Issue.record("switching on from an uninstalled copy changed the state")
            return
        }
    }

    // MARK: - Reaching it

    /// The escape hatch. With every tab-bearing module switched off the panel
    /// has nowhere to open, so this is what makes an empty tab list a legal
    /// state rather than a trap.
    @Test func theWindowIsReachedThroughTheSpyWithoutTouchingAWindowServer() {
        let delegate = makeDelegate()
        var shown = 0
        let controller = PreferencesController(
            switchboard: delegate.switchboard,
            state: delegate.state,
            launchAtLogin: delegate.launchAtLogin,
            presenter: { _ in shown += 1 }
        )

        controller.show()
        controller.show()

        #expect(shown == 2)
    }
}
