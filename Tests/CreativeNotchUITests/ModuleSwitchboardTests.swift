import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// The one place that starts and stops every module.
///
/// Every assertion here is against the **subsystem**, never the stored
/// boolean. The failure this whole module exists to prevent is the preference
/// being recorded correctly, the UI updating correctly, and the subsystem
/// carrying on running -- and a test that asserts the Bool passes right
/// through it.
///
/// Every disable test pre-asserts that the subsystem was running, in the same
/// function. `install(metrics:)` starts nothing, so these assertions are
/// vacuous at rest: not-started is indistinguishable from stopped.
@MainActor
struct ModuleSwitchboardTests {

    private func makeDelegate() -> AppDelegate {
        let delegate = AppDelegate()
        delegate.preferencesDefaults = TestDefaults.isolated("switchboard")
        delegate.growthDelay = .zero
        delegate.shelfDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CreativeNotchSwitchboard-\(UUID().uuidString)")
        delegate.playChime = {}
        delegate.install(metrics: NotchedDelegate.metrics)
        // Neither the real repeating Timer nor a real perl subprocess.
        delegate.clipboard?.poller.scheduleTimer = { _, _ in nil }
        delegate.clipboard?.poller.cancelTimer = { _ in }
        delegate.media?.supervisor.startHelper = {}
        delegate.media?.supervisor.stopHelper = {}
        return delegate
    }

    // MARK: - The launch path and a live toggle are the same code

    /// R5. If launch kept its own list, "off at launch" and "turned off at
    /// runtime" would drift -- and the one that drifts is always the launch
    /// path, because a developer's machine has every module on.
    @Test func aModuleDisabledBeforeLaunchNeverStarts() throws {
        let delegate = makeDelegate()
        delegate.preferencesStore.setEnabled(false, for: .clipboard)
        let clipboard = try #require(delegate.clipboard)

        delegate.startSubsystems()

        #expect(clipboard.poller.scheduledInterval == nil)
        delegate.activity.stop()
    }

    /// The ON case is what makes the OFF case mean anything: `nil` is also
    /// what a poller that was never started looks like.
    @Test func aModuleEnabledBeforeLaunchStarts() throws {
        let delegate = makeDelegate()
        let clipboard = try #require(delegate.clipboard)

        delegate.startSubsystems()

        #expect(clipboard.poller.scheduledInterval == ClipboardPollSchedule.activeInterval)
        delegate.activity.stop()
    }

    /// The same for the hotkey, and it matters more here than anywhere: a
    /// system-wide registration made at launch for a module the user switched
    /// off is a key that opens the panel with the switch reading off.
    @Test func aHotkeyDisabledBeforeLaunchIsNeverRegistered() throws {
        let delegate = makeDelegate()
        let hotkey = try #require(delegate.hotkey)
        hotkey.setCombo(HotKeyCombo(
            keyCode: UInt32(kVK_F13),
            carbonModifiers: HotKeyModifier.control | HotKeyModifier.option | HotKeyModifier.shift
        ))
        hotkey.stop()
        delegate.preferencesStore.setEnabled(false, for: .hotkey)

        delegate.startSubsystems()

        #expect(hotkey.isRegistered == false)
        #expect(HotKeyCenter.shared.registrationCount == 0)
        delegate.activity.stop()
    }

    /// The ON case, or the above passes against an `apply()` that registers
    /// nothing at all.
    @Test func aHotkeyEnabledBeforeLaunchIsRegistered() throws {
        let delegate = makeDelegate()
        let hotkey = try #require(delegate.hotkey)
        hotkey.setCombo(HotKeyCombo(
            keyCode: UInt32(kVK_F13),
            carbonModifiers: HotKeyModifier.control | HotKeyModifier.option | HotKeyModifier.shift
        ))
        hotkey.stop()

        delegate.startSubsystems()

        #expect(hotkey.isRegistered)
        hotkey.stop()
        delegate.activity.stop()
    }

    // MARK: - Quit

    /// R11. The old stop list had five entries; the switchboard owns seven.
    /// This is the one lifecycle call site that is drivable from a test.
    @Test func terminatingStopsEverythingThatWasRunning() throws {
        let delegate = makeDelegate()
        let clipboard = try #require(delegate.clipboard)
        let media = try #require(delegate.media)
        var stops = 0
        media.supervisor.stopHelper = { stops += 1 }

        delegate.startSubsystems()
        #expect(clipboard.poller.scheduledInterval != nil)
        #expect(delegate.power?.isObserving == true)

        delegate.applicationWillTerminate(Notification(name: .init("t")))

        #expect(clipboard.poller.scheduledInterval == nil)
        #expect(stops >= 1)
        #expect(delegate.power?.isObserving == false)
    }

    // MARK: - It registers nothing

    /// R6. The switchboard is the one-line addition the fan-out comment
    /// promised, wearing a name -- not a second observer.
    @Test func theSwitchboardRegistersNoSecondObserver() {
        let delegate = makeDelegate()
        let observers = delegate.stateObserverCount

        delegate.activity.start()

        #expect(delegate.activity.tokenCount == 4)
        #expect(delegate.stateObserverCount == observers)
        delegate.activity.stop()
    }

    /// Constructing a delegate must not read the defaults domain. `apply()`
    /// is the only thing that consults storage, which is what lets the
    /// fourteen suites that call `install` and then inject fakes keep
    /// asserting ungated behaviour unchanged.
    @Test func installingReadsNoPreferencesAndStartsNothing() throws {
        let delegate = makeDelegate()
        let clipboard = try #require(delegate.clipboard)

        #expect(delegate.switchboard.preferences == .allEnabled)
        #expect(clipboard.poller.scheduledInterval == nil)
        #expect(delegate.power?.isObserving == false)
        #expect(delegate.hud?.keys.isRunning == false)
    }
}
