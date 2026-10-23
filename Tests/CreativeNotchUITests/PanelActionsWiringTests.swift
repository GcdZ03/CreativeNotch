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

    /// Clear moves real files to the Trash, so it is offered back for a
    /// few seconds: Undo restores them, and the offer goes once used.
    @Test func clearShelfCanBeUndone() throws {
        let d = makeDelegate()
        let shelf = try #require(d.shelf)
        let item = try shelf.add(.text("keep me"), now: Date())
        #expect(d.state.canUndoShelfClear == false)

        d.state.onClearShelf?()
        #expect(shelf.items.isEmpty)
        #expect(d.state.canUndoShelfClear)

        d.state.onUndoClearShelf?()

        #expect(shelf.items.map(\.id) == [item.id])
        #expect(try String(contentsOf: item.url, encoding: .utf8) == "keep me")
        #expect(d.state.canUndoShelfClear == false)
    }

    /// The menu bar's Clear Shelf is the same verb, so it is undoable too.
    @Test func theMenuBarsClearIsTheUndoableOne() throws {
        let d = makeDelegate()
        let shelf = try #require(d.shelf)
        try shelf.add(.text("x"), now: Date())

        d.clearShelf()

        #expect(shelf.items.isEmpty)
        #expect(d.state.canUndoShelfClear)
    }

    /// The offer is a one-shot that lapses on its own -- nothing repeats,
    /// and nothing is left scheduled once it has.
    @Test func theUndoOfferLapses() async throws {
        let d = makeDelegate()
        d.shelfUndoWindow = .milliseconds(20)
        let shelf = try #require(d.shelf)
        try shelf.add(.text("x"), now: Date())

        d.state.onClearShelf?()
        #expect(d.state.canUndoShelfClear)

        try await Task.sleep(for: .milliseconds(300))

        #expect(d.state.canUndoShelfClear == false)
        #expect(d.shelfUndoTask == nil)
        d.state.onUndoClearShelf?()
        #expect(shelf.items.isEmpty, "an undo that had lapsed still restored")
    }

    /// Clearing an empty shelf takes nothing, so offers nothing back.
    @Test func clearingAnEmptyShelfOffersNoUndo() {
        let d = makeDelegate()
        d.state.onClearShelf?()
        #expect(d.state.canUndoShelfClear == false)
        #expect(d.shelfUndoTask == nil)
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
