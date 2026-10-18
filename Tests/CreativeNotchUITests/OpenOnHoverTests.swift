import AppKit
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// "Open on hover" from the app's side (2026-10-17): the dwell follows the
/// setting, a dwell opens the panel instead of peeking when it is on, and
/// Settings persists and applies it in one call.
@MainActor
struct OpenOnHoverTests {

    private static let track = TrackSnapshot(title: "Song", artist: "Band", isPlaying: true)
    private static let on = HoverBehaviour(opensOnHover: true, openDelay: 0.6)

    // MARK: - The dwell

    /// The tracker asks how long to wait each time the pointer arrives, so
    /// a changed setting applies on the next hover with nothing to re-sync.
    @Test func theTrackerWaitsForTheConfiguredDwell() {
        let d = NotchedDelegate.make()
        #expect(d.hoverView?.currentDwell() == .milliseconds(300))
        d.state.onSetHoverBehaviour?(Self.on)
        #expect(d.hoverView?.currentDwell() == .milliseconds(600))
    }

    // MARK: - What a dwell does

    @Test func withTheSettingOffADwellStillPeeks() {
        let d = NotchedDelegate.make()
        d.nowPlayingDidChange(Self.track)
        d.hoverView?.onDwell()
        #expect(d.state.state == .peek(.nowPlaying(Self.track)))
    }

    /// With it on, the dwell opens the panel — on the last tab, through
    /// the same path the shortcut uses.
    @Test func withTheSettingOnADwellOpensThePanel() {
        let d = NotchedDelegate.make()
        d.state.onSetHoverBehaviour?(Self.on)
        d.hoverView?.onDwell()
        #expect(d.state.state == .open(d.state.lastOpenTab))
    }

    /// Straight to the panel even with music playing: one expansion, never
    /// a peek that then expands again by itself (2026-10-18). The panel's
    /// music column has the progress bar, so nothing the peek showed is
    /// lost.
    @Test func withMusicItOpensStraightToThePanel() {
        let d = NotchedDelegate.make()
        d.state.onSetHoverBehaviour?(Self.on)
        d.nowPlayingDidChange(Self.track)
        d.hoverView?.onDwell()
        if case .open = d.state.state {} else { Issue.record("expected the panel, got \(d.state.state)") }
    }

    @Test func aDragInFlightIsNotInterrupted() {
        let d = NotchedDelegate.make()
        d.state.onSetHoverBehaviour?(Self.on)
        d.state.transition(to: .receiving)
        d.hoverView?.onDwell()
        #expect(d.state.state == .receiving)
    }

    /// With every tab switched off there is no panel to open, so the dwell
    /// falls back to peeking — or to nothing.
    @Test func withNoTabsItDoesNotOpenAnEmptyPanel() {
        let d = NotchedDelegate.make()
        d.state.onSetHoverBehaviour?(Self.on)
        for module in ModuleID.allCases { d.switchboard.setEnabled(false, for: module, persist: false) }
        d.hoverView?.onDwell()
        if case .open = d.state.state { Issue.record("opened a panel with no tabs") }
    }

    // MARK: - Leaving

    /// A panel hover opened, hover closes: leaving starts the same grace the
    /// open panel always had.
    @Test func leavingAHoverOpenedPanelClosesItAfterTheGrace() async {
        let d = NotchedDelegate.make()
        d.dismissGrace = .milliseconds(10)
        d.state.onSetHoverBehaviour?(Self.on)
        d.hoverView?.onDwell()
        #expect(d.state.state == .open(d.state.lastOpenTab))
        d.hoverView?.onExit()
        await d.graceTask?.value
        #expect(d.state.state == .closed)
    }

    // MARK: - Persisting

    @Test func theSettingIsSavedAndRestoredOnTheNextLaunch() {
        let defaults = TestDefaults.isolated("open-on-hover")
        let first = AppDelegate()
        first.preferencesDefaults = defaults
        first.playChime = {}
        first.install(metrics: NotchedDelegate.metrics)
        first.state.onSetHoverBehaviour?(Self.on)

        let second = AppDelegate()
        second.preferencesDefaults = defaults
        second.playChime = {}
        second.install(metrics: NotchedDelegate.metrics)
        #expect(second.state.hoverBehaviour == Self.on)
    }

    /// Settings goes through the verb, and reads back what applied.
    @Test func settingsWritesThroughTheVerb() {
        let d = NotchedDelegate.make()
        let controller = PreferencesController(
            switchboard: d.switchboard, state: d.state, launchAtLogin: d.launchAtLogin
        )
        controller.setHoverBehaviour(Self.on)
        #expect(d.state.hoverBehaviour == Self.on)
        #expect(controller.hoverBehaviour == Self.on)
    }
}
