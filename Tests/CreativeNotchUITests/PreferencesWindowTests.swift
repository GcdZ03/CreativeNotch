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
        delegate.clipboard?.poller.scheduleTimer = { _, _ in nil }
        delegate.clipboard?.poller.cancelTimer = { _ in }
        delegate.media?.supervisor.startHelper = {}
        delegate.media?.supervisor.stopHelper = {}
        return delegate
    }

    private func makeController(_ delegate: AppDelegate) -> PreferencesController {
        PreferencesController(switchboard: delegate.switchboard, state: delegate.state)
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
            presenter: { _ in shown += 1 }
        )

        controller.show()
        controller.show()

        #expect(shown == 2)
    }
}
