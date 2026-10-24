import AppKit
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// Search and pinning in the clipboard pane, from the app's side: where the
/// query lives and when it goes, what Esc does with it, and that a pin
/// reaches the ring and survives the paths that empty it.
///
/// What a query matches and how pins order and evict are pure and pinned in
/// Core (`ClipboardSearchTests`, `ClipboardPinTests`).
@MainActor
struct ClipboardSearchPinWiringTests {

    private func makeDelegate() -> AppDelegate {
        let d = NotchedDelegate.make()
        d.takeKey = {}
        return d
    }

    private func openClipboard(_ d: AppDelegate) {
        d.toggleFromHotKey()
        d.state.transition(to: .open(.clipboard))
    }

    // MARK: - The query

    @Test func aFreshStateHasNoSearch() {
        #expect(AppState().clipboardQuery == "")
    }

    /// A search is part of one look at the history: switching tabs and back
    /// keeps it, closing the panel ends it, so the next open shows the whole
    /// list rather than a filter nobody remembers typing.
    @Test func theSearchLastsUntilThePanelCloses() {
        let s = AppState()
        s.transition(to: .open(.clipboard))
        s.clipboardQuery = "invoice"
        s.transition(to: .open(.shelf))
        #expect(s.clipboardQuery == "invoice")
        s.transition(to: .open(.clipboard))
        #expect(s.clipboardQuery == "invoice")
        s.transition(to: .closed)
        #expect(s.clipboardQuery == "")
    }

    @Test func escapeClearsTheSearchThenCloses() {
        let d = makeDelegate()
        openClipboard(d)
        d.state.clipboardQuery = "invoice"

        #expect(d.handlePanelKey(.escape))
        #expect(d.state.clipboardQuery == "")
        #expect(d.state.state == .open(.clipboard))

        #expect(d.handlePanelKey(.escape))
        #expect(d.state.state == .closed)
    }

    /// The installed panel's own Esc — the route a focused search field
    /// takes, as `cancelOperation` — clears the search first too.
    @Test func escapeFromTheFocusedFieldClearsTheSearch() throws {
        let d = makeDelegate()
        openClipboard(d)
        d.state.clipboardQuery = "invoice"
        let panel = try #require(d.panel)

        panel.cancelOperation(nil)

        #expect(d.state.clipboardQuery == "")
        #expect(d.state.state == .open(.clipboard))
    }

    /// The search field must never be the reason the panel takes the
    /// keyboard: a hover-open of the clipboard tab leaves it with the app
    /// underneath, as it does for every tab but the timer.
    @Test func aHoverOpenOfTheClipboardDoesNotTakeTheKeyboard() {
        #expect(!AppDelegate.shouldTakeKey(for: .open(.clipboard), openedBy: .hover))
        #expect(AppDelegate.shouldTakeKey(for: .open(.clipboard), openedBy: .tap))
    }

    /// An `.accessory` app has no Edit menu, so the panel itself turns ⌘V
    /// and friends into the field editor's actions — or pasting a word into
    /// the search would do nothing.
    @Test func theEditingChordsDecodeForAFieldInThePanel() {
        #expect(NotchPanel.editingAction(characters: "v", modifiers: .command) == #selector(NSText.paste(_:)))
        #expect(NotchPanel.editingAction(characters: "c", modifiers: .command) == #selector(NSText.copy(_:)))
        #expect(NotchPanel.editingAction(characters: "x", modifiers: .command) == #selector(NSText.cut(_:)))
        #expect(NotchPanel.editingAction(characters: "a", modifiers: .command) == #selector(NSText.selectAll(_:)))
        #expect(NotchPanel.editingAction(characters: "z", modifiers: .command) == Selector(("undo:")))
        #expect(NotchPanel.editingAction(characters: "v", modifiers: [.command, .capsLock]) != nil)
        #expect(NotchPanel.editingAction(characters: "v", modifiers: []) == nil, "typing a v is typing")
        #expect(NotchPanel.editingAction(characters: "v", modifiers: [.command, .shift]) == nil)
        #expect(NotchPanel.editingAction(characters: "q", modifiers: .command) == nil)
    }

    // MARK: - Pins

    @Test func installingWiresThePinHandler() {
        #expect(makeDelegate().state.onTogglePinClipboardEntry != nil)
    }

    @Test func thePinHandlerPinsAndUnpins() throws {
        let d = makeDelegate()
        let store = try #require(d.state.clipboard)
        let a = try #require(store.record(.text("A"), now: Date(timeIntervalSince1970: 0)))
        store.record(.text("B"), now: Date(timeIntervalSince1970: 1))

        d.state.onTogglePinClipboardEntry?(a.id)
        #expect(store.entries.first?.id == a.id)
        #expect(store.entries.first?.isPinned == true)

        d.state.onTogglePinClipboardEntry?(a.id)
        #expect(store.entries.allSatisfy { !$0.isPinned })
    }

    /// The pane's Clear and the menu bar's leave pins where they are.
    @Test func clearKeepsThePins() throws {
        let d = makeDelegate()
        let store = try #require(d.state.clipboard)
        let a = try #require(store.record(.text("A"), now: Date(timeIntervalSince1970: 0)))
        store.record(.text("B"), now: Date(timeIntervalSince1970: 1))
        store.pin(a.id)

        d.state.onClearClipboard?()

        #expect(store.entries.map(\.id) == [a.id])
    }

    /// Off means the app holds nothing — pins are no exception.
    @Test func switchingTheModuleOffForgetsThePins() throws {
        let d = makeDelegate()
        let store = try #require(d.state.clipboard)
        let a = try #require(store.record(.text("A"), now: Date(timeIntervalSince1970: 0)))
        store.pin(a.id)

        d.switchboard.setEnabled(false, for: .clipboard, persist: false)

        #expect(store.entries.isEmpty)
    }

    // MARK: - The pane's title row

    @Test func clearIsOfferedOnlyWhileThereIsSomethingToClear() throws {
        let s = AppState()
        let store = ClipboardStore()
        #expect(NotchRootView.clipboardActions(for: store, app: s).isEmpty)

        let a = try #require(store.record(.text("A"), now: Date(timeIntervalSince1970: 0)))
        #expect(NotchRootView.clipboardActions(for: store, app: s).map(\.label) == ["Clear"])

        store.pin(a.id)
        #expect(NotchRootView.clipboardActions(for: store, app: s).isEmpty,
                "Clear would do nothing to a history of pins")
    }

    /// The count says how many of how many while searching, so an empty
    /// filtered list never reads as an empty history.
    @Test func theCountSaysWhatTheSearchKept() throws {
        let store = ClipboardStore()
        #expect(NotchRootView.clipboardCount(for: store, query: "") == nil)
        store.record(.text("apple"), now: Date(timeIntervalSince1970: 0))
        store.record(.text("banana"), now: Date(timeIntervalSince1970: 1))
        #expect(NotchRootView.clipboardCount(for: store, query: "")
                == "2 of \(ClipboardStore.defaultCapacity)")
        #expect(NotchRootView.clipboardCount(for: store, query: "app") == "1 of 2")
    }

    // MARK: - The menu bar

    /// "Clear Clipboard (n)" counts what Clear takes, so a history of pins
    /// alone offers nothing to clear.
    @Test func theMenuBarCountsWhatClearWouldTake() throws {
        let d = makeDelegate()
        let store = try #require(d.state.clipboard)
        let a = try #require(store.record(.text("A"), now: Date(timeIntervalSince1970: 0)))
        store.record(.text("B"), now: Date(timeIntervalSince1970: 1))
        store.pin(a.id)

        #expect(d.menuClipboardCount == 1)
    }
}

/// A row's Pin and Unpin, and what VoiceOver hears of a pinned row.
struct ClipboardRowPinTests {

    @Test func anUnpinnedRowOffersPin() {
        let actions = ClipboardRowModel.rowActions(
            isPinned: false, canPin: true, onCopy: {}, onTogglePin: {}, onRemove: {})
        #expect(actions.map(\.label) == ["Copy", "Pin", "Remove"])
        #expect(actions.map(\.symbolName) == ["doc.on.doc", "pin", "xmark"])
        #expect(actions.allSatisfy { $0.isEnabled })
    }

    @Test func aPinnedRowOffersUnpin() {
        let actions = ClipboardRowModel.rowActions(
            isPinned: true, canPin: false, onCopy: {}, onTogglePin: {}, onRemove: {})
        #expect(actions.map(\.label) == ["Copy", "Unpin", "Remove"])
        #expect(actions[1].symbolName == "pin.slash")
        #expect(actions[1].isEnabled, "a pin can always be taken out, at the limit above all")
    }

    /// At the limit, Pin is still in the menu, greyed and saying why, rather
    /// than missing — a verb that comes and goes reads as a bug.
    @Test func atTheLimitPinIsShownDisabledWithItsReason() {
        let actions = ClipboardRowModel.rowActions(
            isPinned: false, canPin: false, onCopy: {}, onTogglePin: {}, onRemove: {})
        #expect(actions[1].label == "Pin (\(ClipboardStore.maxPinned) already pinned)")
        #expect(!actions[1].isEnabled)
    }

    /// VoiceOver's named actions are what can be done: a disabled verb
    /// offered there would be one that silently does nothing.
    @Test func voiceOverIsOfferedPinAndRemove() {
        let open = ClipboardRowModel.rowActions(
            isPinned: false, canPin: true, onCopy: {}, onTogglePin: {}, onRemove: {})
        #expect(ClipboardRowModel.accessibilityActions(open).map(\.label) == ["Pin", "Remove"])

        let full = ClipboardRowModel.rowActions(
            isPinned: false, canPin: false, onCopy: {}, onTogglePin: {}, onRemove: {})
        #expect(ClipboardRowModel.accessibilityActions(full).map(\.label) == ["Remove"])
    }

    @Test func pinPerformsItsOwnVerb() {
        var calls: [String] = []
        let actions = ClipboardRowModel.rowActions(
            isPinned: false, canPin: true,
            onCopy: { calls.append("copy") },
            onTogglePin: { calls.append("pin") },
            onRemove: { calls.append("remove") })
        for action in actions { action.perform() }
        #expect(calls == ["copy", "pin", "remove"])
    }

    @Test func voiceOverHearsThatARowIsPinned() {
        let entry = ClipboardEntry(id: UUID(), content: .text("hello"), addedAt: Date(),
                                   isPinned: true)
        #expect(ClipboardRowModel.accessibilityLabel(entry: entry, time: "10:42")
                == "Pinned, Copy hello, added 10:42")
    }

    @Test func theAnnouncementsSayWhatHappened() {
        #expect(ClipboardRowModel.pinAnnouncement(pinned: true) == "Pinned")
        #expect(ClipboardRowModel.pinAnnouncement(pinned: false) == "Unpinned")
    }

    @Test func anEmptySearchSaysWhatWasSearchedFor() {
        #expect(ClipboardRowModel.noMatchesText(query: "  invoice ") == "No matches for “invoice”")
    }
}
