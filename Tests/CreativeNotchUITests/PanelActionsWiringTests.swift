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
        delegate.shelfTrash = TestTrash.shelf
        delegate.preferencesDefaults = TestDefaults.isolated("panel-actions")
        delegate.growthDelay = .zero
        delegate.shelfDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CreativeNotchPanelActions-\(UUID().uuidString)")
        delegate.install(metrics: Self.notched)
        // Never the real Settings window from a test.
        delegate.presentPreferences = { _ in }
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

        // Awaited rather than slept past: under a parallel suite the main
        // actor can be busy for longer than any fixed margin.
        let offer = try #require(d.shelfUndoTask)
        await offer.value

        #expect(d.state.canUndoShelfClear == false)
        #expect(d.shelfUndoTask == nil)
        d.state.onUndoClearShelf?()
        #expect(shelf.items.isEmpty, "an undo that had lapsed still restored")
    }

    /// Two clears inside the window are one undo. Before, the second clear's
    /// record replaced the first's, and the first batch stayed in the Trash
    /// with no button left that pointed at it.
    @Test func undoRestoresEveryClearMadeWhileTheOfferStood() throws {
        let d = makeDelegate()
        let shelf = try #require(d.shelf)
        let first = try shelf.add(.text("first"), now: Date())
        d.clearShelf()
        let second = try shelf.add(.text("second"), now: Date().addingTimeInterval(1))
        d.clearShelf()
        #expect(shelf.items.isEmpty)

        d.undoClearShelf()

        #expect(shelf.items.map(\.id) == [second.id, first.id])
        #expect(d.state.canUndoShelfClear == false)
    }

    /// A lapsed offer is not merged into the next one: after the window,
    /// a clear starts a fresh undo.
    @Test func aClearAfterTheOfferLapsedStartsAFreshUndo() async throws {
        let d = makeDelegate()
        d.shelfUndoWindow = .milliseconds(20)
        let shelf = try #require(d.shelf)
        try shelf.add(.text("gone for good"), now: Date())
        d.clearShelf()
        let offer = try #require(d.shelfUndoTask)
        await offer.value

        d.shelfUndoWindow = AppDelegate.defaultShelfUndoWindow
        let kept = try shelf.add(.text("kept"), now: Date().addingTimeInterval(1))
        d.clearShelf()
        d.undoClearShelf()

        #expect(shelf.items.map(\.id) == [kept.id])
    }

    /// What an undo could not bring back is said under the shelf and to
    /// VoiceOver, through the notice a failed copy already uses -- not just
    /// logged where nobody looks.
    @Test func itemsThatCannotBeRestoredAreReported() throws {
        let d = makeDelegate()
        var spoken: [String] = []
        d.announce = { spoken.append($0) }
        let shelf = try #require(d.shelf)
        let external = d.shelfDirectory.deletingLastPathComponent()
            .appendingPathComponent("CreativeNotchUndoRef-\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: external)
        try shelf.addReference(to: external, now: Date())
        d.clearShelf()
        // The referenced file goes away while the undo is on offer.
        let elsewhere = external.deletingLastPathComponent()
            .appendingPathComponent("CreativeNotchUndoMoved-\(UUID().uuidString).txt")
        try FileManager.default.moveItem(at: external, to: elsewhere)

        d.undoClearShelf()

        #expect(shelf.items.isEmpty)
        #expect(d.state.shelfNotice == "Couldn't restore 1 item")
        #expect(spoken == ["Couldn't restore 1 item"])
    }

    /// Everything came back, so there is nothing to say.
    @Test func aCleanUndoSaysNothing() throws {
        let d = makeDelegate()
        var spoken: [String] = []
        d.announce = { spoken.append($0) }
        let shelf = try #require(d.shelf)
        try shelf.add(.text("x"), now: Date())
        d.clearShelf()
        d.undoClearShelf()
        #expect(d.state.shelfNotice == nil)
        #expect(spoken.isEmpty)
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
        d.presentPreferences = { _ in presented += 1 }
        d.state.transition(to: .open(.shelf))

        d.state.onOpenSettings?()

        #expect(d.state.state == .closed)
        #expect(presented == 1)
    }
}
