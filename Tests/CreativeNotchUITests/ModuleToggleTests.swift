import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// The toggle that stops the subsystem.
///
/// **This is the suite where a green result is least reassuring.** The
/// preference will be stored correctly and the UI will update correctly
/// whether or not the subsystem actually stops, so every assertion here is
/// against the subsystem and never against the stored boolean.
///
/// Every disable test starts the module and asserts it is running *in the same
/// function*. That middle step is not decoration: at rest `scheduledInterval`
/// is nil, `isObserving` is false and `state.nowPlaying` is nil, so without it
/// every one of these passes with the toggle deleted. The discipline is stated
/// verbatim in `SystemActivityFanOutTests`: *not suspended is indistinguishable
/// from resumed*.
@MainActor
struct ModuleToggleTests {

    private func makeDelegate() -> AppDelegate {
        let delegate = AppDelegate()
        delegate.preferencesDefaults = TestDefaults.isolated("toggle")
        delegate.growthDelay = .zero
        delegate.shelfDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CreativeNotchToggle-\(UUID().uuidString)")
        delegate.playChime = {}
        delegate.install(metrics: NotchedDelegate.metrics)
        delegate.clipboard?.poller.scheduleTimer = { _, _ in nil }
        delegate.clipboard?.poller.cancelTimer = { _ in }
        delegate.media?.supervisor.startHelper = {}
        delegate.media?.supervisor.stopHelper = {}
        return delegate
    }

    // MARK: - Clipboard

    /// R2. Deleting one `setActivity` line once left 471 tests green while
    /// the helper ran on through lock and sleep. This is that assertion for
    /// a preference.
    @Test func disablingClipboardStopsTheOnlyRepeatingTimerInTheProject() throws {
        let delegate = makeDelegate()
        let clipboard = try #require(delegate.clipboard)
        delegate.startSubsystems()
        #expect(clipboard.poller.scheduledInterval == ClipboardPollSchedule.activeInterval)

        delegate.switchboard.setEnabled(false, for: .clipboard)

        #expect(clipboard.poller.scheduledInterval == nil)
        delegate.activity.stop()
    }

    /// R8. Twice, in both directions: a preference snapshotted at
    /// construction works exactly once, and `HUDController` has an in-repo
    /// example of that pattern which must not be copied.
    @Test func aModuleFollowsTheToggleEveryTimeItMoves() throws {
        let delegate = makeDelegate()
        let clipboard = try #require(delegate.clipboard)
        delegate.startSubsystems()

        delegate.switchboard.setEnabled(false, for: .clipboard)
        #expect(clipboard.poller.scheduledInterval == nil)

        delegate.switchboard.setEnabled(true, for: .clipboard)
        #expect(clipboard.poller.scheduledInterval == ClipboardPollSchedule.activeInterval)

        delegate.switchboard.setEnabled(false, for: .clipboard)
        #expect(clipboard.poller.scheduledInterval == nil)
        delegate.activity.stop()
    }

    // MARK: - Power

    @Test func disablingPowerStopsObserving() throws {
        let delegate = makeDelegate()
        delegate.startSubsystems()
        #expect(delegate.power?.isObserving == true)

        delegate.switchboard.setEnabled(false, for: .power)

        #expect(delegate.power?.isObserving == false)
        #expect(delegate.state.power == nil)
        delegate.activity.stop()
    }

    /// R3, at the visible layer. An arbiter assertion alone proves nothing:
    /// the arbiter is queried rather than pushed, so a peek withdrawn from it
    /// is still on screen until something re-asks.
    @Test func disablingPowerTakesItsPeekOffTheScreen() {
        let delegate = makeDelegate()
        delegate.showPowerPeek(.unplugged(level: 66))
        #expect(delegate.state.state == .peek(.power(.unplugged(level: 66))))

        delegate.switchboard.setEnabled(false, for: .power)

        #expect(delegate.state.state == .closed)
        #expect(delegate.state.power == nil)
    }

    /// Capability and preference are two values. `hasBattery` answers "can
    /// this machine do it", is rewritten on every power notification, and
    /// would clobber a preference folded into it.
    @Test func disablingPowerLeavesTheHardwareFactAlone() {
        let delegate = makeDelegate()
        delegate.powerDidChange(PowerSnapshot(level: 50, source: .battery,
                                              isCharging: false, isLowPowerMode: false))
        #expect(delegate.state.hasBattery)

        delegate.switchboard.setEnabled(false, for: .power)

        #expect(delegate.state.hasBattery, "hasBattery is a capability, not a preference")
    }

    // MARK: - System HUD

    /// The HUD owns the app's one admitted always-installed global monitor --
    /// a `CGEventTap` -- so this is the highest-value toggle in the set.
    ///
    /// The running half needs Accessibility, which a CI runner cannot grant,
    /// so the flag is captured once and asserted softly; the hard consequence
    /// is asserted unconditionally only inside `if started`. That is the shape
    /// `HUDControllerTests.stopStopsAllThreeOwnedSources` worked out, and a
    /// genuine regression on a host where the source did start is still caught
    /// loudly.
    @Test func disablingTheHudReleasesItsObservers() throws {
        let delegate = makeDelegate()
        delegate.startSubsystems()
        let hud = try #require(delegate.hud)

        let keysStarted = hud.keys.isRunning
        expectOrKnownHardwareIssue(
            keysStarted,
            "CGEventTapCreate fails without Accessibility granted to the process, which a CI runner cannot grant"
        )
        let volumeStarted = hud.volume.isRunning
        expectOrKnownHardwareIssue(
            volumeStarted,
            "CI runners intermittently have no audio device (actions/runner-images#13668)"
        )

        delegate.switchboard.setEnabled(false, for: .hud)

        if keysStarted { #expect(hud.keys.isRunning == false) }
        if volumeStarted { #expect(hud.volume.isRunning == false) }
        delegate.activity.stop()
    }

    /// And the HUD's peek is withdrawn rather than waited out. This half
    /// needs no hardware: the arbiter is driven directly.
    @Test func disablingTheHudWithdrawsItsPeek() {
        let delegate = makeDelegate()
        delegate.showHUD(.volume(0.5))
        #expect(delegate.state.state == .peek(.hud(HUDEvent(kind: .volume(0.5)))))

        delegate.switchboard.setEnabled(false, for: .hud)

        #expect(delegate.state.state == .closed)
    }

    // MARK: - Media metadata

    /// R1 as a gesture, through the delegate rather than the controller.
    @Test func disablingMediaAndThenUnlockingLeavesTheHelperStopped() throws {
        let delegate = makeDelegate()
        let media = try #require(delegate.media)
        var starts = 0
        media.supervisor.startHelper = { starts += 1 }
        delegate.startSubsystems()
        #expect(starts == 1, "not started is indistinguishable from not resurrected")

        delegate.switchboard.setEnabled(false, for: .mediaMetadata)
        let baseline = starts

        delegate.activity.handle(.screenLocked)
        delegate.activity.handle(.screenUnlocked)

        #expect(starts == baseline)
        #expect(media.supervisor.helperIsRunning == false)
        delegate.activity.stop()
    }

    /// The stale now-playing badge widens the closed notch's hit-test region
    /// forever, which is the failure `nowPlayingDidChange` warns about.
    @Test func disablingMediaNarrowsTheClosedNotchBackToItsBareWidth() throws {
        let delegate = makeDelegate()
        delegate.startSubsystems()
        delegate.nowPlayingDidChange(TrackSnapshot(title: "T", artist: "A", isPlaying: true))
        let badged = delegate.acceptedRect.width
        #expect(badged > 230, "the badge never widened the region, so the test proves nothing")

        delegate.switchboard.setEnabled(false, for: .mediaMetadata)

        #expect(delegate.state.nowPlaying == nil)
        #expect(delegate.acceptedRect.width == 230)
        delegate.activity.stop()
    }

    // MARK: - Media transport

    /// Asserts the injected probe rather than the resolved boolean, which is
    /// false anyway on a host with no MediaRemote. **The count is what proves
    /// the lazy `&&` is the right way round** -- reading availability performs
    /// a `dlopen` that has no matching `dlclose`.
    @Test func disablingTransportControlsDoesNotLoadMediaRemote() {
        let delegate = AppDelegate()
        var probes = 0
        delegate.mediaRemoteAvailable = { probes += 1; return true }
        delegate.preferencesDefaults = TestDefaults.isolated("transport")
        delegate.growthDelay = .zero
        delegate.shelfDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CreativeNotchTransport-\(UUID().uuidString)")
        delegate.install(metrics: NotchedDelegate.metrics)
        delegate.clipboard?.poller.scheduleTimer = { _, _ in nil }
        delegate.clipboard?.poller.cancelTimer = { _ in }
        delegate.media?.supervisor.startHelper = {}
        delegate.media?.supervisor.stopHelper = {}
        delegate.preferencesStore.setEnabled(false, for: .mediaControls)
        let afterInstall = probes

        delegate.startSubsystems()

        #expect(probes == afterInstall, "the preference must be the left operand of the &&")
        #expect(delegate.state.showsMediaControls == false)
        #expect(delegate.state.onMediaCommand == nil)
        delegate.activity.stop()
    }

    // MARK: - Shelf

    @Test func disablingTheShelfTakesItOutOfThePanel() {
        let delegate = makeDelegate()
        #expect(delegate.state.shelf != nil)

        delegate.switchboard.setEnabled(false, for: .shelf)

        #expect(delegate.state.shelf == nil)
    }

    // MARK: - Camera

    /// Switching the module off stops the capture and takes the session out of
    /// the panel -- the preview must not keep a graph alive behind a switch
    /// that reads off.
    @Test func disablingTheCameraStopsItAndClearsTheSession() throws {
        let delegate = makeDelegate()
        let camera = try #require(delegate.camera)
        camera.authorizationStatus = { .authorized }
        delegate.startSubsystems()
        delegate.switchboard.setEnabled(true, for: .camera)
        camera.setTabVisible(true)
        #expect(camera.shouldRun, "the camera never started, so stopping it proves nothing")

        delegate.switchboard.setEnabled(false, for: .camera)

        #expect(camera.shouldRun == false)
        #expect(delegate.state.cameraSession == nil)
        #expect(delegate.state.isRecordingClip == false)
        delegate.activity.stop()
    }

    /// The camera tab disappears with the module, like every other tab.
    @Test func disablingTheCameraRemovesItsTab() {
        let delegate = makeDelegate()
        #expect(TabVisibility.visible(enabled: delegate.state.preferences,
                                      hasBattery: true).contains(.camera))

        delegate.switchboard.setEnabled(false, for: .camera)

        #expect(!TabVisibility.visible(enabled: delegate.state.preferences,
                                       hasBattery: true).contains(.camera))
    }

    // MARK: - Global hotkey

    /// Stopping this module means **unregistering**, not ignoring the
    /// callback. A system-wide registration alive while the switch reads off
    /// is the sharpest version of the failure this whole module exists to
    /// prevent -- the key still opens the panel.
    @Test func disablingTheHotkeyDropsItsRegistration() throws {
        let delegate = makeDelegate()
        let hotkey = try #require(delegate.hotkey)
        delegate.startSubsystems()
        hotkey.setCombo(HotKeyCombo(
            keyCode: UInt32(kVK_F13),
            carbonModifiers: HotKeyModifier.control | HotKeyModifier.option | HotKeyModifier.shift
        ))
        #expect(hotkey.isRegistered, "nothing was registered, so nothing is proved by it stopping")

        delegate.switchboard.setEnabled(false, for: .hotkey)

        #expect(hotkey.isRegistered == false)
        #expect(HotKeyCenter.shared.isHandlerInstalled == false,
                "the process-wide handler outlived the module")
        delegate.activity.stop()
    }

    /// And re-enabling brings it back, or the toggle works exactly once.
    @Test func reEnablingTheHotkeyRegistersItAgain() throws {
        let delegate = makeDelegate()
        let hotkey = try #require(delegate.hotkey)
        delegate.startSubsystems()
        hotkey.setCombo(HotKeyCombo(
            keyCode: UInt32(kVK_F13),
            carbonModifiers: HotKeyModifier.control | HotKeyModifier.option | HotKeyModifier.shift
        ))
        delegate.switchboard.setEnabled(false, for: .hotkey)

        delegate.switchboard.setEnabled(true, for: .hotkey)

        #expect(hotkey.isRegistered)
        hotkey.stop()
        delegate.activity.stop()
    }

    /// The hotkey opens the panel, and closes it again -- a key that opens but
    /// cannot close is a key you press and then reach for the mouse.
    @Test func theHotkeyTogglesThePanel() {
        let delegate = makeDelegate()
        #expect(delegate.state.state == .closed)

        delegate.toggleFromHotKey()
        #expect(delegate.state.state == .open(.shelf))

        delegate.toggleFromHotKey()
        #expect(delegate.state.state == .closed)
    }

    /// With every tab-bearing module switched off there is nothing to open, so
    /// the hotkey is a deliberate no-op rather than opening an empty panel.
    @Test func theHotkeyOpensNothingWhenEveryTabIsGone() {
        let delegate = makeDelegate()
        for module in [ModuleID.shelf, .clipboard, .timer, .power, .camera] {
            delegate.switchboard.setEnabled(false, for: module)
        }

        delegate.toggleFromHotKey()

        #expect(delegate.state.state == .closed)
    }

    // MARK: - The tab that has just disappeared (R7)

    @Test func disablingTheOpenTabMovesToAVisibleOne() {
        let delegate = makeDelegate()
        delegate.state.transition(to: .open(.clipboard))

        delegate.switchboard.setEnabled(false, for: .clipboard)

        #expect(delegate.state.state == .open(.shelf))
        #expect(delegate.state.lastOpenTab == .shelf)
    }

    /// Fixing only the live state leaves the notch tap to reopen a dead tab
    /// minutes later -- and it must not open the panel to do the correcting.
    @Test func disablingAClosedPanelsLastTabRetargetsItWithoutOpening() {
        let delegate = makeDelegate()
        delegate.state.transition(to: .open(.clipboard))
        delegate.state.transition(to: .closed)
        #expect(delegate.state.lastOpenTab == .clipboard)

        delegate.switchboard.setEnabled(false, for: .clipboard)

        #expect(delegate.state.lastOpenTab == .shelf)
        #expect(delegate.state.state == .closed, "changing a setting opened the panel")
    }

    /// Switching off every tab-bearing module is a legal state, not a trap:
    /// the preferences window is reached from the menu bar.
    @Test func switchingEverythingOffClosesThePanelRatherThanStranding() {
        let delegate = makeDelegate()
        delegate.state.transition(to: .open(.shelf))

        for module in [ModuleID.shelf, .clipboard, .timer, .power, .camera] {
            delegate.switchboard.setEnabled(false, for: module)
        }

        #expect(delegate.state.state == .closed)
    }
}
