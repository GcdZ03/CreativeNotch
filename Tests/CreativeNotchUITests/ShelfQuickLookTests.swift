import AppKit
import QuickLookUI
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// Quick Look and Open on the shelf, from the app's side: that Space, the
/// arrows, a tile's verbs and the module switch reach the seams with the
/// right files.
///
/// The rules are pinned in Core (`ShelfPreviewTests`). Nothing here puts a
/// `QLPreviewPanel` on screen or launches an app: the delegate's preview and
/// opener are stand-ins — sandboxed by default, and replaced here by
/// recorders — and the real `ShelfQuickLook` is exercised only as a data
/// source, with no panel ever asked for.
@MainActor
struct ShelfQuickLookTests {

    /// Counts what it was asked to show, and is "visible" from a show until
    /// a close, as the real panel is.
    final class RecordingPreview: ShelfPreviewing {
        var shown: [ShelfPreviewRequest] = []
        var closes = 0
        var isVisible = false
        let isSystem = false
        func show(_ request: ShelfPreviewRequest) { shown.append(request); isVisible = true }
        func close() { closes += 1; isVisible = false }
    }

    private struct Setup {
        let delegate: AppDelegate
        let preview: RecordingPreview
        let opened: () -> [URL]
        let shelf: ShelfStore
    }

    /// `NotchedDelegate.make()`, unless a test needs to hold a copy open:
    /// the copier has to be handed over before `install` builds the shelf.
    private func makeSetup(copier: ShelfCopier? = nil) throws -> Setup {
        let delegate: AppDelegate
        if let copier {
            delegate = AppDelegate()
            delegate.shelfTrash = TestTrash.shelf
            delegate.shelfCopier = copier
            delegate.preferencesDefaults = TestDefaults.isolated()
            delegate.growthDelay = .zero
            delegate.announce = { _ in }
            delegate.pointerLocation = { CGPoint(x: -10_000, y: -10_000) }
            delegate.install(metrics: NotchedDelegate.metrics)
        } else {
            delegate = NotchedDelegate.make()
        }
        let preview = RecordingPreview()
        var opened: [URL] = []
        delegate.shelfPreview = preview
        delegate.shelfOpener = ShelfOpener(isSystem: false) { opened.append($0); return true }
        let shelf = try #require(delegate.shelf)
        return Setup(delegate: delegate, preview: preview, opened: { opened }, shelf: shelf)
    }

    /// Two text drops: small, synchronous, and real files in the sandboxed
    /// shelf folder.
    @discardableResult
    private func addTwo(_ shelf: ShelfStore) throws -> (ShelfItem, ShelfItem) {
        let first = try shelf.add(.text("one"), now: Date())
        let second = try shelf.add(.text("two"), now: Date())
        return (first, second)
    }

    // MARK: - Space

    @Test func spaceOnTheShelfPreviewsTheSelectionAmongTheReadyItems() throws {
        let s = try makeSetup()
        let (first, second) = try addTwo(s.shelf)
        s.delegate.state.transition(to: .open(.shelf))
        s.delegate.state.shelfSelection = first.id

        #expect(s.delegate.handlePanelKey(.space))

        let request = try #require(s.preview.shown.last)
        #expect(Set(request.urls) == Set([first.url, second.url]))
        #expect(request.current == first.url)
    }

    /// Space with nothing selected previews the first tile and selects it,
    /// so the ring shows what Quick Look is showing.
    @Test func spaceWithNothingSelectedPreviewsAndSelectsTheFirstTile() throws {
        let s = try makeSetup()
        try addTwo(s.shelf)
        s.delegate.state.transition(to: .open(.shelf))

        #expect(s.delegate.handlePanelKey(.space))

        let first = try #require(s.shelf.readyItems.first)
        #expect(s.preview.shown.last?.current == first.url)
        #expect(s.delegate.state.shelfSelection == first.id)
    }

    /// Space toggles, as it does in Finder.
    @Test func spaceAgainClosesThePreview() throws {
        let s = try makeSetup()
        try addTwo(s.shelf)
        s.delegate.state.transition(to: .open(.shelf))

        s.delegate.handlePanelKey(.space)
        #expect(s.delegate.handlePanelKey(.space))

        #expect(s.preview.closes == 1)
        #expect(s.preview.shown.count == 1)
    }

    /// An empty shelf has nothing to show; the key goes back to AppKit.
    @Test func spaceOnAnEmptyShelfIsPassedOn() throws {
        let s = try makeSetup()
        s.delegate.state.transition(to: .open(.shelf))
        #expect(!s.delegate.handlePanelKey(.space))
        #expect(s.preview.shown.isEmpty)
    }

    @Test func spaceOffTheShelfTabIsPassedOn() throws {
        let s = try makeSetup()
        try addTwo(s.shelf)
        s.delegate.state.transition(to: .open(.clipboard))
        #expect(!s.delegate.handlePanelKey(.space))
        #expect(s.preview.shown.isEmpty)
    }

    // MARK: - Arrows

    @Test func theArrowsMoveTheSelection() throws {
        let s = try makeSetup()
        try addTwo(s.shelf)
        let ready = s.shelf.readyItems
        s.delegate.state.transition(to: .open(.shelf))

        #expect(s.delegate.handlePanelKey(.arrowRight))
        #expect(s.delegate.state.shelfSelection == ready[0].id)
        s.delegate.handlePanelKey(.arrowRight)
        #expect(s.delegate.state.shelfSelection == ready[1].id)
        s.delegate.handlePanelKey(.arrowLeft)
        #expect(s.delegate.state.shelfSelection == ready[0].id)
        // Not previewing, so moving shows nothing.
        #expect(s.preview.shown.isEmpty)
    }

    /// While the preview is up and the panel still has the keys, the preview
    /// follows the selection.
    @Test func movingTheSelectionWhilePreviewingShowsTheNewTile() throws {
        let s = try makeSetup()
        try addTwo(s.shelf)
        let ready = s.shelf.readyItems
        s.delegate.state.transition(to: .open(.shelf))
        s.delegate.state.shelfSelection = ready[0].id
        s.delegate.handlePanelKey(.space)

        s.delegate.handlePanelKey(.arrowRight)

        #expect(s.preview.shown.last?.current == ready[1].url)
    }

    // MARK: - The tile's verbs

    @Test func installingWiresQuickLookAndOpen() throws {
        let s = try makeSetup()
        #expect(s.delegate.state.onQuickLookShelfItem != nil)
        #expect(s.delegate.state.onOpenShelfItem != nil)
    }

    @Test func theQuickLookVerbPreviewsThatTileAndSelectsIt() throws {
        let s = try makeSetup()
        let (_, second) = try addTwo(s.shelf)
        s.delegate.state.onQuickLookShelfItem?(second.id)
        #expect(s.preview.shown.last?.current == second.url)
        #expect(s.delegate.state.shelfSelection == second.id)
    }

    @Test func theOpenVerbOpensThatFileWithTheDefaultApp() throws {
        let s = try makeSetup()
        let (first, _) = try addTwo(s.shelf)
        s.delegate.state.onOpenShelfItem?(first.id)
        #expect(s.opened() == [first.url])
    }

    /// A file still copying in has nothing to open or preview, whatever
    /// reaches the verb.
    @Test func aCopyingItemIsNeitherOpenedNorPreviewed() async throws {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let s = try makeSetup(copier: ShelfCopier(
            copy: { _, _ in for await _ in stream {}; throw CancellationError() },
            availableCapacity: { _ in nil }
        ))
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("ql-src-\(UUID().uuidString).mov")
        try Data("x".utf8).write(to: source)
        let pending = try s.shelf.add(.file(source), now: Date())
        #expect(pending.isPending)

        s.delegate.state.onOpenShelfItem?(pending.id)
        s.delegate.state.onQuickLookShelfItem?(pending.id)

        #expect(s.opened().isEmpty)
        #expect(s.preview.shown.isEmpty)
        continuation.finish()
        await s.shelf.waitForPendingCopies()
    }

    // MARK: - The line under the tiles

    /// A selected tile says how to preview and open it — the one place the
    /// panel writes Space and the double-click down.
    @Test func aSelectedTileExplainsSpaceAndDoubleClick() throws {
        let s = try makeSetup()
        let (first, _) = try addTwo(s.shelf)
        #expect(NotchRootView.shelfFooter(notice: nil, selection: first.id, in: s.shelf.items)
            == "Space to Quick Look · double-click to open")
    }

    /// A failed copy is news and wins over the hint.
    @Test func aNoticeWinsOverTheHint() throws {
        let s = try makeSetup()
        let (first, _) = try addTwo(s.shelf)
        #expect(NotchRootView.shelfFooter(notice: "Couldn't add A.mov", selection: first.id, in: s.shelf.items)
            == "Couldn't add A.mov")
    }

    /// Nothing selected, or a selection that has gone: no line at all.
    @Test func noSelectionNoHint() throws {
        let s = try makeSetup()
        try addTwo(s.shelf)
        #expect(NotchRootView.shelfFooter(notice: nil, selection: nil, in: s.shelf.items) == nil)
        #expect(NotchRootView.shelfFooter(notice: nil, selection: UUID(), in: s.shelf.items) == nil)
    }

    @Test func theRingIsDrawnOnlyOnASelectedReadyTile() {
        let ready = ShelfItem(id: UUID(), url: URL(fileURLWithPath: "/tmp/a"), displayName: "a", addedAt: Date())
        let copying = ShelfItem(id: UUID(), url: URL(fileURLWithPath: "/tmp/b"), displayName: "b",
                                addedAt: Date(), isPending: true)
        #expect(ShelfView.isSelected(ready, selection: ready.id))
        #expect(!ShelfView.isSelected(ready, selection: nil))
        #expect(!ShelfView.isSelected(copying, selection: copying.id))
    }

    // MARK: - The module switch

    /// Switching the shelf off takes the preview of its files down with it,
    /// and forgets the selection.
    @Test func switchingTheShelfOffClosesThePreview() throws {
        let s = try makeSetup()
        try addTwo(s.shelf)
        s.delegate.state.transition(to: .open(.shelf))
        s.delegate.handlePanelKey(.space)

        s.delegate.switchboard.setEnabled(false, for: .shelf)

        #expect(s.preview.closes == 1)
        #expect(s.delegate.state.shelfSelection == nil)
    }

    /// The control: a module switch that leaves the shelf on leaves the
    /// preview alone.
    @Test func switchingAnotherModuleOffLeavesThePreview() throws {
        let s = try makeSetup()
        try addTwo(s.shelf)
        s.delegate.state.transition(to: .open(.shelf))
        s.delegate.handlePanelKey(.space)

        s.delegate.switchboard.setEnabled(false, for: .clipboard)

        #expect(s.preview.closes == 0)
    }

    // MARK: - The real data source, without a panel

    /// What `QLPreviewPanel` would read, asked directly: the panel itself is
    /// never created, so nothing appears on the machine running the suite.
    @Test func theQuickLookDataSourceServesTheRequestedFiles() throws {
        let quickLook = ShelfQuickLook()
        let urls = [URL(fileURLWithPath: "/tmp/a.pdf"), URL(fileURLWithPath: "/tmp/b.png")]
        quickLook.load(ShelfPreviewRequest(urls: urls, index: 1))

        #expect(quickLook.numberOfPreviewItems(in: nil) == 2)
        let item = try #require(quickLook.previewPanel(nil, previewItemAt: 1))
        #expect(item.previewItemURL == urls[1])
        #expect(quickLook.previewPanel(nil, previewItemAt: 5) == nil)
    }

    /// A fresh `ShelfQuickLook` asks nothing of Quick Look: reading whether
    /// a preview is up must not be what creates the shared panel.
    @Test func askingWhetherAPreviewIsUpCreatesNoPanel() {
        let quickLook = ShelfQuickLook()
        // Another suite in the process may already have made one; then
        // there is nothing left to prove here.
        guard !QLPreviewPanel.sharedPreviewPanelExists() else { return }
        #expect(!quickLook.isVisible)
        quickLook.close()
        #expect(!QLPreviewPanel.sharedPreviewPanelExists())
    }
}
