import AppKit
import Foundation
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// The excluded-apps list, from Settings to the poller (2026-10-24).
///
/// Matching is `ClipboardExclusionsTests`' and the capture-time read is
/// `ClipboardPollerTests`'; this pins that the list Settings edits is the one
/// the running poller consults, saved and applied in one call. No test opens
/// a real `NSOpenPanel`: the chooser is a seam.
@MainActor
struct ClipboardExclusionWiringTests {

    private func makeDelegate(defaults: UserDefaults = TestDefaults.isolated("clip-exclude")) -> AppDelegate {
        let delegate = AppDelegate()
        delegate.shelfTrash = TestTrash.shelf
        delegate.preferencesDefaults = defaults
        delegate.growthDelay = .zero
        delegate.playChime = { _ in }
        delegate.announce = { _ in }
        delegate.screenDescriptors = { [] }
        delegate.install(metrics: NotchedDelegate.metrics)
        delegate.capture?.observer.readCurrentUse = { .none }
        delegate.clipboard?.poller.scheduleTimer = { _, _ in nil }
        delegate.clipboard?.poller.cancelTimer = { _ in }
        return delegate
    }

    private func makeController(_ delegate: AppDelegate, choosing chosen: [String] = []) -> PreferencesController {
        let controller = PreferencesController(
            switchboard: delegate.switchboard,
            state: delegate.state,
            launchAtLogin: delegate.launchAtLogin,
            presenter: { _ in }
        )
        controller.chooseApps = { chosen }
        return controller
    }

    @Test func theListIsLoadedAtInstall() {
        let defaults = TestDefaults.isolated("clip-exclude")
        PreferencesStore(defaults: defaults).setClipboardExcludedApps(["com.apple.Terminal"])
        let delegate = makeDelegate(defaults: defaults)
        #expect(delegate.state.clipboardExcludedApps == ["com.apple.Terminal"])
    }

    /// Live: the poller asks the delegate at each change, so a list edited
    /// while history is running applies to the very next copy.
    @Test func theRunningPollerSeesTheEditedList() throws {
        let delegate = makeDelegate()
        let poller = try #require(delegate.clipboard?.poller)
        #expect(poller.excludedApps() == [])

        delegate.state.onSetClipboardExcludedApps?(["com.apple.Terminal"])

        #expect(poller.excludedApps() == ["com.apple.Terminal"])
        #expect(PreferencesStore(defaults: delegate.preferencesDefaults).clipboardExcludedApps
                == ["com.apple.Terminal"])
    }

    @Test func plusAddsWhatWasChosenAndMinusRemovesIt() {
        let delegate = makeDelegate()
        let controller = makeController(delegate, choosing: ["com.apple.Terminal", "com.apple.Notes"])

        controller.addExcludedApps()
        #expect(controller.clipboardExcludedApps == ["com.apple.Terminal", "com.apple.Notes"])

        // Choosing one already listed adds nothing.
        controller.addExcludedApps()
        #expect(controller.clipboardExcludedApps == ["com.apple.Terminal", "com.apple.Notes"])

        controller.removeExcludedApp("com.apple.Terminal")
        #expect(controller.clipboardExcludedApps == ["com.apple.Notes"])
        #expect(delegate.clipboard?.poller.excludedApps() == ["com.apple.Notes"])
    }

    /// Cancelling the open panel chooses nothing and changes nothing.
    @Test func cancellingTheChooserChangesNothing() {
        let delegate = makeDelegate()
        let defaults = delegate.preferencesDefaults
        let controller = makeController(delegate, choosing: [])
        controller.addExcludedApps()
        #expect(controller.clipboardExcludedApps == [])
        #expect(defaults.object(forKey: PreferenceKeys.clipboardExcludedApps) == nil)
    }

    @Test func theTimerNoticeSwitchWritesThroughTheController() {
        let delegate = makeDelegate()
        let controller = makeController(delegate)
        #expect(controller.timerNotifyWhenHidden)
        controller.setTimerNotifyWhenHidden(false)
        #expect(delegate.state.timerNotifyWhenHidden == false)
        #expect(controller.timerNotifyWhenHidden == false)
    }

    /// An app that is not installed is still listed, by its identifier, so
    /// it can be removed.
    @Test func anUninstalledAppIsListedByItsIdentifier() {
        let app = ExcludedApp(bundleID: "com.example.not-installed-\(UUID().uuidString)")
        #expect(app.name == app.bundleID)
    }
}
