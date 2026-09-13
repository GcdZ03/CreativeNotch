import AppKit
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// The pane's title-row actions reach the verbs that already exist. Left
/// unwired, a Clear button that does nothing is worse than no button.
@MainActor
struct PanelActionsWiringTests {

    /// The same literal `AppDelegateStateFunnelTests` uses.
    private static let notched = ScreenMetrics(
        frame: CGRect(x: 1470, y: 200, width: 1470, height: 956),
        safeAreaTopInset: 38,
        auxiliaryTopLeftWidth: 620,
        auxiliaryTopRightWidth: 620,
        menuBarHeight: 38
    )

    private func makeDelegate() -> AppDelegate {
        let delegate = AppDelegate()
        delegate.preferencesDefaults = TestDefaults.isolated("panel-actions")
        delegate.growthDelay = .zero
        delegate.shelfDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CreativeNotchPanelActions-\(UUID().uuidString)")
        delegate.install(metrics: Self.notched)
        // Never the real Settings window from a test.
        delegate.presentPreferences = {}
        return delegate
    }

    @Test func installingWiresEveryPaneAction() {
        let d = makeDelegate()
        #expect(d.state.onClearShelf != nil)
        #expect(d.state.onRemoveShelfItem != nil)
        #expect(d.state.onClearClipboard != nil)
        #expect(d.state.onOpenSettings != nil)
    }

    @Test func clearShelfEmptiesTheStore() throws {
        let d = makeDelegate()
        let shelf = try #require(d.shelf)
        let file = d.shelfDirectory.appendingPathComponent("a.txt")
        try Data("x".utf8).write(to: file)
        try shelf.addReference(to: file, now: Date())
        #expect(shelf.items.count == 1)

        d.state.onClearShelf?()

        #expect(shelf.items.isEmpty)
    }

    @Test func removeShelfItemRemovesJustThatOne() throws {
        let d = makeDelegate()
        let shelf = try #require(d.shelf)
        let a = d.shelfDirectory.appendingPathComponent("a.txt")
        let b = d.shelfDirectory.appendingPathComponent("b.txt")
        try Data("x".utf8).write(to: a)
        try Data("y".utf8).write(to: b)
        let first = try shelf.addReference(to: a, now: Date())
        try shelf.addReference(to: b, now: Date().addingTimeInterval(1))
        #expect(shelf.items.count == 2)

        d.state.onRemoveShelfItem?(first.id)

        #expect(shelf.items.map(\.displayName) == ["b.txt"])
    }

    @Test func clearClipboardEmptiesTheRing() throws {
        let d = makeDelegate()
        let store = try #require(d.state.clipboard)
        _ = store.record(.text("hello"), now: Date())
        #expect(store.entries.count == 1)

        d.state.onClearClipboard?()

        #expect(store.entries.isEmpty)
    }

    /// Settings is an activating window; the panel closes before it opens.
    @Test func openSettingsClosesThePanelFirst() {
        let d = makeDelegate()
        var presented = 0
        d.presentPreferences = { presented += 1 }
        d.state.transition(to: .open(.shelf))

        d.state.onOpenSettings?()

        #expect(d.state.state == .closed)
        #expect(presented == 1)
    }
}
