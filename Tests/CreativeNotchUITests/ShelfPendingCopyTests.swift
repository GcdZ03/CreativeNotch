import AppKit
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// A dropped file copying in the background, as the drop path, the tile and
/// the pane see it. The store's own rules are in `ShelfAsyncCopyTests`.
///
/// No test here trashes anything: the only items are pending ones, text, or
/// files that are never removed.
@MainActor
struct ShelfPendingCopyTests {

    private static let notched = ScreenMetrics(
        frame: CGRect(x: 1470, y: 200, width: 1470, height: 956),
        safeAreaTopInset: 38,
        auxiliaryTopLeftWidth: 620,
        auxiliaryTopRightWidth: 620,
        menuBarHeight: 38
    )

    private struct CopyFailed: Error {}

    private func makeDelegate(copier: ShelfCopier = .system) -> AppDelegate {
        let delegate = AppDelegate()
        delegate.preferencesDefaults = TestDefaults.isolated("shelf-pending")
        delegate.growthDelay = .zero
        delegate.shelfDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shelf-\(UUID().uuidString)")
        delegate.shelfCopier = copier
        delegate.install(metrics: Self.notched)
        return delegate
    }

    private func makeSourceFile(named name: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data("contents".utf8).write(to: url)
        return url
    }

    /// A copier that holds every copy until `release` finishes the stream,
    /// then fails it -- so a store can be shown with a pending item and
    /// tidied up afterwards without a sleep.
    private func heldCopier() -> (ShelfCopier, release: () -> Void) {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let copier = ShelfCopier(
            copy: { _, _ in
                for await _ in stream {}
                throw CopyFailed()
            },
            availableCapacity: { _ in nil }
        )
        return (copier, { continuation.finish() })
    }

    // MARK: - The drop path

    /// The drop is answered at once -- accepted, the shelf opened -- with
    /// the file listed as pending, and it turns ready when the copy lands.
    @Test func aFileDropIsAcceptedBeforeItsCopyFinishes() async throws {
        let delegate = makeDelegate()
        let container = try #require(delegate.panel?.contentView as? PassthroughContainer)
        let shelf = try #require(delegate.shelf)
        let source = try makeSourceFile(named: "movie.mov")

        container.onDragEntered()
        let accepted = container.onDrop([.file(source)])

        #expect(accepted)
        #expect(delegate.state.state == .open(.shelf))
        #expect(shelf.items.first?.isPending == true)

        await shelf.waitForPendingCopies()
        #expect(shelf.items.first?.isPending == false)
        #expect(FileManager.default.fileExists(atPath: try #require(shelf.items.first).url.path))
    }

    /// Spec section 9, for what is known at drop time: a file that is gone
    /// is refused, not accepted and failed a moment later.
    @Test func aDropOfAMissingFileIsRefused() throws {
        let delegate = makeDelegate()
        let container = try #require(delegate.panel?.contentView as? PassthroughContainer)
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gone-\(UUID().uuidString).mov")

        container.onDragEntered()
        let accepted = container.onDrop([.file(missing)])

        #expect(accepted == false)
        #expect(delegate.state.state == .closed)
        #expect(delegate.shelf?.items.isEmpty == true)
    }

    /// The same for a file drop onto a shelf directory that cannot be
    /// written -- the file twin of `aDropThatCannotBeStoredIsRefused`.
    @Test func aFileDropOntoAnUnwritableShelfIsRefused() throws {
        let delegate = makeDelegate()
        let container = try #require(delegate.panel?.contentView as? PassthroughContainer)
        let source = try makeSourceFile(named: "notes.txt")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: delegate.shelfDirectory.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: delegate.shelfDirectory.path)
        }

        container.onDragEntered()
        let accepted = container.onDrop([.file(source)])

        #expect(accepted == false)
        #expect(delegate.shelf?.items.isEmpty == true)
    }

    // MARK: - A copy that fails later

    /// The drop already said yes, so the failure is said in the pane --
    /// briefly, by a one-shot that withdraws it and is then gone.
    @Test func aFailedCopyIsMentionedInThePaneAndThenWithdrawn() async throws {
        let failing = ShelfCopier(copy: { _, _ in throw CopyFailed() }, availableCapacity: { _ in nil })
        let delegate = makeDelegate(copier: failing)
        delegate.shelfNoticeDuration = .milliseconds(20)
        let container = try #require(delegate.panel?.contentView as? PassthroughContainer)
        let shelf = try #require(delegate.shelf)
        let source = try makeSourceFile(named: "Holiday.mov")

        #expect(container.onDrop([.file(source)]))
        await shelf.waitForPendingCopies()

        #expect(shelf.items.isEmpty)
        #expect(delegate.state.shelfNotice == "Couldn't add Holiday.mov")

        // Awaited rather than slept past, as the undo offer's test does.
        let notice = try #require(delegate.shelfNoticeTask)
        await notice.value
        #expect(delegate.state.shelfNotice == nil)
        #expect(delegate.shelfNoticeTask == nil)
    }

    /// Nothing is scheduled while nothing has failed.
    @Test func noNoticeIsScheduledWhenNothingFailed() {
        let delegate = makeDelegate()
        #expect(delegate.state.shelfNotice == nil)
        #expect(delegate.shelfNoticeTask == nil)
    }

    // MARK: - The tile

    private let pending = ShelfItem(
        id: UUID(),
        url: URL(fileURLWithPath: "/tmp/shelf/Big.mov"),
        displayName: "Big.mov",
        addedAt: Date(),
        isPending: true
    )

    @Test func aPendingTileSaysItIsCopying() {
        #expect(ShelfView.tileAccessibilityLabel(for: pending) == "Big.mov, copying")
    }

    /// Show in Finder, AirDrop and Remove all need the file, which is not
    /// there yet: a pending tile offers none of them, and cannot be dragged.
    @Test func aPendingTileOffersNoVerbsAndCannotBeDragged() {
        let actions = ShelfView.tileActions(for: pending, onRemove: {}, onAirDrop: {}, onReveal: {})
        #expect(actions.isEmpty)
        #expect(!ShelfView.isDraggable(pending))
    }

    /// The control: a ready tile still has its three verbs and drags.
    @Test func aReadyTileKeepsItsVerbsAndDrags() {
        let ready = ShelfItem(id: UUID(), url: pending.url, displayName: "Big.mov", addedAt: Date())
        let actions = ShelfView.tileActions(for: ready, onRemove: {}, onAirDrop: {}, onReveal: {})
        #expect(actions.map(\.label) == ["Show in Finder", "AirDrop", "Remove"])
        #expect(ShelfView.isDraggable(ready))
        #expect(ShelfView.tileAccessibilityLabel(for: ready) == "Big.mov")
    }

    // MARK: - The title row

    /// AirDrop All sends only files that exist, and a shelf holding nothing
    /// but a copy in progress offers neither it nor Clear.
    @Test func theTitleRowActsOnlyOnReadyItems() async throws {
        let (copier, release) = heldCopier()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-\(UUID())")
        let store = try ShelfStore(directory: dir, copier: copier)
        try store.add(.file(try makeSourceFile(named: "Big.mov")), now: Date())

        #expect(NotchRootView.shelfActions(for: store, app: AppState()).isEmpty)

        let text = try store.add(.text("ready"), now: Date())
        let app = AppState()
        var sent: [[URL]] = []
        app.onAirDropShelfItems = { sent.append($0) }
        let actions = NotchRootView.shelfActions(for: store, app: app)
        #expect(actions.map(\.label) == ["AirDrop All", "Clear"])
        actions.first { $0.label == "AirDrop All" }?.perform()
        #expect(sent == [[text.url]])

        release()
        await store.waitForPendingCopies()
    }
}
