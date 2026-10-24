import AppKit
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// That the module is actually connected to the app, rather than merely
/// existing beside it.
@MainActor
struct ClipboardWiringTests {

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
        delegate.preferencesDefaults = TestDefaults.isolated()
        delegate.growthDelay = .zero
        delegate.shelfDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CreativeNotchClipWiring-\(UUID().uuidString)")
        delegate.install(metrics: Self.notched)
        return delegate
    }

    @Test func installingGivesTheStateAClipboardStore() {
        #expect(makeDelegate().state.clipboard != nil)
    }

    /// The view asks for a copy-back through this closure. Left unset,
    /// every click in the clipboard list would silently do nothing.
    @Test func installingWiresTheCopyHandler() {
        #expect(makeDelegate().state.onCopyClipboard != nil)
    }

    @Test func installingWiresTheRemoveHandler() {
        #expect(makeDelegate().state.onRemoveClipboardEntry != nil)
    }

    /// The row's Delete reaches the ring the pane shows, and takes only
    /// the entry it was asked to.
    @Test func removeClipboardEntryRemovesJustThatOne() throws {
        let d = makeDelegate()
        let store = try #require(d.state.clipboard)
        let a = try #require(store.record(.text("A"), now: Date(timeIntervalSince1970: 0)))
        store.record(.text("B"), now: Date(timeIntervalSince1970: 1))

        d.state.onRemoveClipboardEntry?(a.id)

        #expect(store.entries.map(\.content) == [.text("B")])
    }

    // MARK: - Menu bar

    @Test func theClearItemReportsAnEmptyRing() {
        let controller = MenuBarController(
            onShowPreferences: {},
            onClearShelf: {},
            shelfCount: { 0 },
            onClearClipboard: {},
            clipboardCount: { 0 }
        )

        #expect(controller.clearClipboardTitle() == "Clipboard is empty")
    }

    @Test func theClearItemCountsTheRing() {
        let controller = MenuBarController(
            onShowPreferences: {},
            onClearShelf: {},
            shelfCount: { 0 },
            onClearClipboard: {},
            clipboardCount: { 7 }
        )

        #expect(controller.clearClipboardTitle() == "Clear Clipboard (7)")
    }

    @Test func clearingFromTheMenuEmptiesTheRing() {
        let store = ClipboardStore()
        store.record(.text("A"), now: Date())

        let controller = MenuBarController(
            onShowPreferences: {},
            onClearShelf: {},
            shelfCount: { 0 },
            onClearClipboard: { store.clear() },
            clipboardCount: { store.entries.count }
        )
        controller.clearClipboard()

        #expect(store.entries.isEmpty)
    }
}
