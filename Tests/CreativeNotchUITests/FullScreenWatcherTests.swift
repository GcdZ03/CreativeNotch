import AppKit
import Testing
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
}
