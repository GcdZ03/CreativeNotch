import AppKit
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// "Show on" from the app's side (2026-10-24): which events place the panel
/// again, and on which display.
///
/// The display lookup is a seam answering per choice, so nothing here reads
/// the real `NSScreen` list -- the rule behind the real lookup is pinned in
/// `DisplayChoiceTests`.
@MainActor
struct ShowOnDisplayTests {

    /// An external display with no notch: landing on it turns the anchor
    /// into a pill, which is how a test sees that the panel moved.
    private static let external = ScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
        safeAreaTopInset: 0, auxiliaryTopLeftWidth: 0, auxiliaryTopRightWidth: 0, menuBarHeight: 24
    )

    /// The built-in display stays where `NotchedDelegate` installed it; focus
    /// is on the external one.
    private func makeDelegate(choice: DisplayChoice = .focusedWindow) -> (AppDelegate, Box) {
        let d = NotchedDelegate.make()
        let asked = Box()
        d.screenMetrics = { choice in
            asked.choices.append(choice)
            return choice == .builtIn ? NotchedDelegate.metrics : Self.external
        }
        if choice != .focusedWindow { d.state.onSetDisplayChoice?(choice) }
        asked.choices.removeAll()
        return (d, asked)
    }

    final class Box { var choices: [DisplayChoice] = [] }

    // MARK: - Activation

    /// Following focus, an app coming forward on another display takes the
    /// panel with it -- the behaviour from before the setting.
    @Test func followingFocusActivationMovesThePanel() {
        let (d, _) = makeDelegate()
        d.activeApplicationDidChange()
        #expect(d.currentAnchor.isNotch == false)
    }

    /// Pinned, an app switch must not move it, and does not even look.
    @Test func pinnedActivationLeavesThePanelAlone() {
        let (d, asked) = makeDelegate(choice: .builtIn)
        d.activeApplicationDidChange()
        #expect(d.currentAnchor.isNotch)
        #expect(asked.choices.isEmpty)
    }

    // MARK: - Screen changes

    /// A display connected or disconnected places the panel by the choice,
    /// not by focus.
    @Test func aScreenChangeAsksForTheChosenDisplay() {
        let (d, asked) = makeDelegate(choice: .builtIn)
        d.screenParametersDidChange()
        #expect(asked.choices == [.builtIn])
        #expect(d.currentAnchor.isNotch)
    }

    @Test func aScreenChangeFollowingFocusMoves() {
        let (d, asked) = makeDelegate()
        d.screenParametersDidChange()
        #expect(asked.choices == [.focusedWindow])
        #expect(d.currentAnchor.isNotch == false)
    }

    // MARK: - Changing the preference

    /// The change applies at once, not on the next activation.
    @Test func changingTheChoiceRepositionsImmediately() {
        let (d, _) = makeDelegate()
        d.state.onSetDisplayChoice?(.focusedWindow)
        #expect(d.currentAnchor.isNotch == false)
        d.state.onSetDisplayChoice?(.builtIn)
        #expect(d.currentAnchor.isNotch)
        #expect(d.state.displayChoice == .builtIn)
    }

    /// Moving onto another display re-checks full screen there, through the
    /// same `reposition` the watcher suite pins.
    @Test func changingTheChoiceReevaluatesFullScreen() {
        let (d, _) = makeDelegate()
        var shown: [Bool] = []
        d.setPanelShown = { shown.append($0) }
        var fullScreen = false
        let watcher = FullScreenWatcher(
            center: NotificationCenter(),
            readDisplays: {
                [["Display Identifier": "D", "Current Space": ["type": fullScreen ? 4 : 0]]]
            },
            displayUUID: { "D" }
        )
        watcher.onChange = { d.applyFullScreen($0) }
        d.fullScreenWatcher = watcher
        watcher.start()

        fullScreen = true
        d.state.onSetDisplayChoice?(.focusedWindow)

        #expect(shown == [false])
    }

    // MARK: - Persisting

    @Test func theChoiceIsSavedAndRestoredOnTheNextLaunch() {
        let defaults = TestDefaults.isolated("show-on")
        let first = AppDelegate()
        first.preferencesDefaults = defaults
        first.playChime = { _ in }
        first.screenMetrics = { _ in nil }
        first.install(metrics: NotchedDelegate.metrics)
        first.state.onSetDisplayChoice?(.builtIn)

        let second = AppDelegate()
        second.preferencesDefaults = defaults
        second.playChime = { _ in }
        second.install(metrics: NotchedDelegate.metrics)
        #expect(second.state.displayChoice == .builtIn)
    }

    /// Settings goes through the verb, and reads back what applied.
    @Test func settingsWritesThroughTheVerb() {
        let (d, _) = makeDelegate()
        let controller = PreferencesController(
            switchboard: d.switchboard, state: d.state, launchAtLogin: d.launchAtLogin
        )
        controller.setDisplayChoice(.builtIn)
        #expect(d.state.displayChoice == .builtIn)
        #expect(controller.displayChoice == .builtIn)
    }
}
