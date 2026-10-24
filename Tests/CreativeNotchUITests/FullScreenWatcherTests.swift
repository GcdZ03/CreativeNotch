import AppKit
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// Hiding the notch over full-screen apps again (2026-10-17), through a
/// watcher fed a fake Space list and a private notification centre — never
/// the real window server or the real workspace.
@MainActor
struct FullScreenWatcherTests {

    nonisolated private static let uuid = "UUID-1"

    private final class Reader {
        var type = 0
        func displays() -> [[String: Any]] {
            [["Display Identifier": FullScreenWatcherTests.uuid, "Current Space": ["type": type]]]
        }
    }

    private func watcher(_ reader: Reader, center: NotificationCenter) -> (FullScreenWatcher, () -> [Bool]) {
        var seen: [Bool] = []
        let w = FullScreenWatcher(
            center: center,
            readDisplays: { reader.displays() },
            displayUUID: { Self.uuid }
        )
        w.onChange = { seen.append($0) }
        return (w, { seen })
    }

    private func spaceChanged(_ center: NotificationCenter) {
        center.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    }

    @Test func enteringAndLeavingFullScreenIsReported() {
        let reader = Reader()
        let center = NotificationCenter()
        let (w, seen) = watcher(reader, center: center)
        w.start()

        reader.type = 4
        spaceChanged(center)
        reader.type = 0
        spaceChanged(center)

        #expect(seen() == [true, false])
    }

    /// Only changes are reported: switching between two desktops is not news.
    @Test func switchingDesktopsReportsNothing() {
        let reader = Reader()
        let center = NotificationCenter()
        let (w, seen) = watcher(reader, center: center)
        w.start()
        spaceChanged(center)
        spaceChanged(center)
        #expect(seen().isEmpty)
    }

    /// Already full-screen at launch is reported at once.
    @Test func startingInFullScreenReportsIt() {
        let reader = Reader()
        reader.type = 4
        let (w, seen) = watcher(reader, center: NotificationCenter())
        w.start()
        #expect(seen() == [true])
    }

    @Test func stoppingStopsListening() {
        let reader = Reader()
        let center = NotificationCenter()
        let (w, seen) = watcher(reader, center: center)
        w.start()
        w.stop()
        reader.type = 4
        spaceChanged(center)
        #expect(seen().isEmpty)
    }

    /// The real reader resolves the window server function without calling
    /// anything that changes state.
    @Test func theWindowServerStillExportsTheSpaceList() {
        #expect(FullScreenWatcher.skyLightReader() != nil)
    }

    // MARK: - The app

    @Test func fullScreenHidesTheNotchAndClosesThePanel() {
        let d = NotchedDelegate.make()
        var shown: [Bool] = []
        d.setPanelShown = { shown.append($0) }
        d.state.transition(to: .open(.shelf))

        d.applyFullScreen(true)
        #expect(shown == [false])
        #expect(d.state.state == .closed)

        d.applyFullScreen(false)
        #expect(shown == [false, true])
    }

    /// Hidden for a full-screen app, the panel is off screen: the shortcut
    /// must not open it there. It used to go `.open` on an ordered-out
    /// window -- outside-click monitor installed, the window made key --
    /// with nothing visible and nothing to click.
    @Test func theShortcutDoesNotOpenAPanelHiddenForFullScreen() {
        let d = NotchedDelegate.make()
        d.setPanelShown = { _ in }
        var installs = 0
        d.installOutsideClickMonitor = { _ in installs += 1; return NSObject() }
        d.removeOutsideClickMonitor = { _ in }

        d.applyFullScreen(true)
        d.toggleFromHotKey()

        #expect(d.state.state == .closed)
        #expect(installs == 0)
        #expect(d.openPanel(openedBy: .hotKey) == false)

        // And back on a desktop it opens again.
        d.applyFullScreen(false)
        d.toggleFromHotKey()
        #expect(d.state.state == .open(.shelf))
    }

    /// Going full-screen mid-drag ends the drag. The panel is ordered out,
    /// so no `draggingExited` will ever arrive to clear it, and the arbiter
    /// would answer "drag target" to every peek for the rest of the session.
    @Test func goingFullScreenMidDragClearsTheDrag() {
        let d = NotchedDelegate.make()
        d.setPanelShown = { _ in }
        let container = d.panel?.contentView as? PassthroughContainer
        container?.onDragEntered()
        #expect(d.state.state == .receiving)

        d.applyFullScreen(true)

        #expect(d.state.state == .closed)
        #expect(d.arbiter.content(now: d.now()) == nil)
    }

    /// Moving to another display is a different Space list entry. The
    /// watcher only looked again on a Space change, so a panel moved onto a
    /// display showing a full-screen app stayed on top of it (or one moved
    /// off one stayed hidden on a normal desktop).
    @Test func movingToAnotherDisplayReevaluatesFullScreen() {
        let d = NotchedDelegate.make()
        var shown: [Bool] = []
        d.setPanelShown = { shown.append($0) }
        let reader = Reader()
        let watcher = FullScreenWatcher(
            center: NotificationCenter(),
            readDisplays: { reader.displays() },
            displayUUID: { Self.uuid }
        )
        watcher.onChange = { d.applyFullScreen($0) }
        d.fullScreenWatcher = watcher
        watcher.start()

        // The display the panel is about to land on is in full screen.
        reader.type = 4
        let other = ScreenMetrics(
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            safeAreaTopInset: 0,
            auxiliaryTopLeftWidth: 0,
            auxiliaryTopRightWidth: 0,
            menuBarHeight: 24
        )
        #expect(d.reposition(metrics: other))

        #expect(shown == [false])
    }

    /// A screen-parameter change re-evaluates even when the panel did not
    /// move: the arrangement changed, and what is on the panel's display may
    /// have with it.
    @Test func aScreenParameterChangeReevaluatesFullScreen() {
        let d = NotchedDelegate.make()
        var shown: [Bool] = []
        d.setPanelShown = { shown.append($0) }
        let reader = Reader()
        let watcher = FullScreenWatcher(
            center: NotificationCenter(),
            readDisplays: { reader.displays() },
            displayUUID: { Self.uuid }
        )
        watcher.onChange = { d.applyFullScreen($0) }
        d.fullScreenWatcher = watcher
        watcher.start()

        reader.type = 4
        d.screenParametersDidChange(metrics: NotchedDelegate.metrics)

        #expect(shown == [false])
    }
}
