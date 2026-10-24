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
        d.activationScreenMetrics = { choice in
            asked.choices.append(choice)
            return choice == .builtIn ? nil : Self.external
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

    /// An activation with no main screen (an accessory app with no key
    /// window) leaves the panel where it is, as it did before the setting --
    /// it does not fall back to the menu-bar display the way the launch does.
    @Test func anActivationWithNoMainScreenLeavesThePanelAlone() {
        let (d, _) = makeDelegate()
        d.activationScreenMetrics = { _ in nil }
        d.activeApplicationDidChange()
        #expect(d.currentAnchor.isNotch)
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

    // MARK: - Pinned to a specific display

    private static let dellUUID = "8A3F1E2C-1111-4C6B-9A0E-5D7C2B9E4F10"
    private static let pinned = DisplayChoice.display(uuid: dellUUID, name: "DELL U2720Q")
    private static let builtInScreen = ScreenDescriptor(id: 1, isBuiltIn: true, isMain: true, name: "Built-in Retina Display")
    private static let dellScreen = ScreenDescriptor(id: 2, isBuiltIn: false, isMain: false, uuid: dellUUID, name: "DELL U2720Q")

    /// A delegate whose display lookup runs the real Core rule over a list a
    /// test can plug and unplug: the built-in display is `NotchedDelegate`'s
    /// notched one, the Dell is the notchless `external`.
    private func makePinnedDelegate() -> (AppDelegate, Plugs) {
        let d = NotchedDelegate.make()
        let plugs = Plugs()
        plugs.screens = [Self.builtInScreen, Self.dellScreen]
        d.screenDescriptors = { plugs.screens }
        d.screenMetrics = { choice in
            switch choice.screen(in: plugs.screens) {
            case 1: return NotchedDelegate.metrics
            case 2: return Self.external
            default: return nil
            }
        }
        d.activationScreenMetrics = { choice in
            plugs.activationsAsked += 1
            return choice.screenOnActivation(in: plugs.screens) == nil ? nil : Self.external
        }
        return (d, plugs)
    }

    final class Plugs {
        var screens: [ScreenDescriptor] = []
        var activationsAsked = 0
    }

    /// Picking the display moves the panel there at once, as a pill: the
    /// external display has no notch.
    @Test func pinningADisplayMovesThePanelToIt() {
        let (d, _) = makePinnedDelegate()
        d.state.onSetDisplayChoice?(Self.pinned)
        #expect(d.state.displayChoice == Self.pinned)
        #expect(d.currentAnchor.isNotch == false)
    }

    /// Unplugged, the panel goes to the built-in display; plugged back in,
    /// the screen-parameter change returns it -- with the choice untouched
    /// in between.
    @Test func aPinnedDisplayUnpluggedAndReconnected() {
        let (d, plugs) = makePinnedDelegate()
        d.state.onSetDisplayChoice?(Self.pinned)

        plugs.screens = [Self.builtInScreen]
        d.screenParametersDidChange()
        #expect(d.currentAnchor.isNotch)
        #expect(d.state.displayChoice == Self.pinned)

        plugs.screens = [Self.builtInScreen, Self.dellScreen]
        d.screenParametersDidChange()
        #expect(d.currentAnchor.isNotch == false)
    }

    /// Pinned to a display, an app switch neither moves the panel nor asks.
    @Test func aPinnedDisplayIgnoresActivation() {
        let (d, plugs) = makePinnedDelegate()
        d.state.onSetDisplayChoice?(Self.pinned)
        plugs.screens = [Self.builtInScreen]
        d.screenParametersDidChange()
        d.activeApplicationDidChange()
        #expect(d.currentAnchor.isNotch)
        #expect(plugs.activationsAsked == 0)
    }

    /// Moving onto the pinned display when it reconnects re-checks full
    /// screen there, through `reposition`.
    @Test func reconnectingThePinnedDisplayReevaluatesFullScreen() {
        let (d, plugs) = makePinnedDelegate()
        d.state.onSetDisplayChoice?(Self.pinned)
        plugs.screens = [Self.builtInScreen]
        d.screenParametersDidChange()

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
        plugs.screens = [Self.builtInScreen, Self.dellScreen]
        d.screenParametersDidChange()
        #expect(shown == [false])
    }

    // MARK: - The Settings menu

    /// Showing Settings reads the displays connected now -- the reused
    /// window's `.onAppear` would not -- and the menu lists them.
    @Test func showingSettingsRefreshesTheDisplayList() {
        let (d, plugs) = makePinnedDelegate()
        let controller = PreferencesController(
            switchboard: d.switchboard, state: d.state, launchAtLogin: d.launchAtLogin,
            presenter: { _ in }
        )
        #expect(controller.displayOptions.count == 2)
        controller.show()
        #expect(controller.displayOptions.map(\.choice).last == Self.pinned)

        plugs.screens = [Self.builtInScreen]
        controller.show()
        #expect(controller.displayOptions.count == 2)
    }

    /// A cable plugged in while Settings is open reaches the menu through
    /// the screen-parameter change, and an unplugged pin stays listed,
    /// marked as not connected.
    @Test func aScreenChangeRefreshesTheDisplayList() {
        let (d, plugs) = makePinnedDelegate()
        let controller = PreferencesController(
            switchboard: d.switchboard, state: d.state, launchAtLogin: d.launchAtLogin,
            presenter: { _ in }
        )
        controller.show()
        controller.setDisplayChoice(Self.pinned)

        plugs.screens = [Self.builtInScreen]
        d.screenParametersDidChange()
        let last = controller.displayOptions.last
        #expect(last?.choice == Self.pinned)
        #expect(last.map(DisplayRow.title(for:)) == "DELL U2720Q (not connected)")

        plugs.screens = [Self.builtInScreen, Self.dellScreen]
        d.screenParametersDidChange()
        #expect(controller.displayOptions.last.map(DisplayRow.title(for:)) == "DELL U2720Q")
    }

    /// A pinned display renamed since it was picked: the next time the
    /// display list is read with it connected, the stored name is updated
    /// and saved, so Settings names it correctly the next time it is
    /// unplugged -- and the panel does not move, since the display is the
    /// same one.
    @Test func aRenamedPinnedDisplayHasItsNameRefreshed() {
        let (d, plugs) = makePinnedDelegate()
        let stale = DisplayChoice.display(uuid: Self.dellUUID, name: "Old name")
        d.state.onSetDisplayChoice?(stale)
        d.refreshConnectedDisplays()

        #expect(d.state.displayChoice == Self.pinned)
        #expect(PreferencesStore(defaults: d.preferencesDefaults).displayChoice == Self.pinned)
        #expect(d.currentAnchor.isNotch == false)

        // Unplugged, the refreshed name is the one Settings shows.
        plugs.screens = [Self.builtInScreen]
        d.screenParametersDidChange()
        #expect(d.state.displayChoice == Self.pinned)
    }

    @Test func menuTitles() {
        let options = DisplayChoice.options(for: [], current: .display(uuid: Self.dellUUID, name: ""))
        #expect(options.map(DisplayRow.title(for:)) == [
            "Display with the focused window", "Built-in display", "External display (not connected)",
        ])
    }

    // MARK: - Persisting

    @Test func aPinnedDisplayIsRestoredOnTheNextLaunch() {
        let defaults = TestDefaults.isolated("show-on-pinned")
        let first = AppDelegate()
        first.shelfDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("shelf-\(UUID().uuidString)")
        first.shelfTrash = TestTrash.shelf
        first.screenDescriptors = { [] }
        first.announce = { _ in }
        first.preferencesDefaults = defaults
        first.playChime = { _ in }
        first.screenMetrics = { _ in nil }
        first.install(metrics: NotchedDelegate.metrics)
        first.state.onSetDisplayChoice?(Self.pinned)

        let second = AppDelegate()
        second.shelfDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("shelf-\(UUID().uuidString)")
        second.shelfTrash = TestTrash.shelf
        second.screenDescriptors = { [] }
        second.announce = { _ in }
        second.preferencesDefaults = defaults
        second.playChime = { _ in }
        second.install(metrics: NotchedDelegate.metrics)
        #expect(second.state.displayChoice == Self.pinned)
    }

    @Test func theChoiceIsSavedAndRestoredOnTheNextLaunch() {
        let defaults = TestDefaults.isolated("show-on")
        let first = AppDelegate()
        first.shelfDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("shelf-\(UUID().uuidString)")
        first.shelfTrash = TestTrash.shelf
        first.preferencesDefaults = defaults
        first.playChime = { _ in }
        first.screenMetrics = { _ in nil }
        first.install(metrics: NotchedDelegate.metrics)
        first.state.onSetDisplayChoice?(.builtIn)

        let second = AppDelegate()
        second.shelfDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("shelf-\(UUID().uuidString)")
        second.shelfTrash = TestTrash.shelf
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
