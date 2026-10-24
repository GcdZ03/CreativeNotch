import Foundation
import Testing
@testable import CreativeNotchCore

/// What lowering a shelf limit would take, answered before anything is
/// taken (2026-10-24) — the question Settings asks so it can confirm first.
///
/// The pure function is tested over hand-built items, with no disk at all.
/// The store-level tests use `SandboxTrash`, so nothing they evict reaches
/// the real `~/.Trash`.
@MainActor
struct ShelfLimitPreviewTests {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let day: TimeInterval = 24 * 3600

    /// Newest first, as the store lists them: `ages[i]` days old at `t0`.
    private func items(agedDays ages: [Double], owned: Bool = true) -> [ShelfItem] {
        ages.enumerated().map { index, age in
            ShelfItem(
                id: UUID(),
                url: URL(fileURLWithPath: "/nowhere/item-\(index)"),
                displayName: "item-\(index)",
                addedAt: t0.addingTimeInterval(-age * day),
                isOwned: owned
            )
        }
    }

    // MARK: - The pure function

    @Test func loweringTheCapacityTakesTheOldestBeyondIt() {
        let listed = items(agedDays: [0, 1, 2, 3, 4])
        let removed = ShelfStore.removals(from: listed, capacity: 3, maxAge: nil, now: t0)
        #expect(removed.items.map(\.id) == listed.suffix(2).map(\.id))
    }

    @Test func shorteningTheExpiryTakesWhatIsOlderThanIt() {
        let listed = items(agedDays: [0, 2, 8, 9])
        let removed = ShelfStore.removals(from: listed, capacity: 50, maxAge: 7 * day, now: t0)
        #expect(removed.items.map(\.id) == listed.suffix(2).map(\.id))
    }

    /// Both at once, without counting an item twice: one past the capacity
    /// *and* the expiry is one file.
    @Test func bothLimitsTogetherCountEachItemOnce() {
        let listed = items(agedDays: [0, 2, 8, 9])
        let removed = ShelfStore.removals(from: listed, capacity: 3, maxAge: 7 * day, now: t0)
        #expect(removed.items.map(\.id) == listed.suffix(2).map(\.id))
        #expect(removed.count == 2)
    }

    /// Never switches the purge off, so no age is too old for it.
    @Test func neverExpiryTakesNothingByAge() {
        let listed = items(agedDays: [0, 365, 3650])
        let removed = ShelfStore.removals(from: listed, capacity: 50, maxAge: nil, now: t0)
        #expect(removed.isEmpty)
    }

    /// The common case, and the one that must stay silent in Settings.
    @Test func raisingALimitTakesNothing() {
        let listed = items(agedDays: [0, 1, 2])
        #expect(ShelfStore.removals(from: listed, capacity: 50, maxAge: 30 * day, now: t0).isEmpty)
    }

    /// The same floor `setLimits` applies, so the two never disagree about
    /// a capacity of zero.
    @Test func aCapacityBelowOneIsTreatedAsOne() {
        let listed = items(agedDays: [0, 1, 2])
        let removed = ShelfStore.removals(from: listed, capacity: 0, maxAge: nil, now: t0)
        #expect(removed.items.map(\.id) == listed.suffix(2).map(\.id))
    }

    /// An item exactly at the limit is kept, as `purge` keeps it (`>`).
    @Test func anItemExactlyAtTheExpiryIsKept() {
        let listed = items(agedDays: [7])
        #expect(ShelfStore.removals(from: listed, capacity: 50, maxAge: 7 * day, now: t0).isEmpty)
    }

    // MARK: - What the confirmation says

    @Test func ownedFilesAreCountedAsMovesToTheTrash() {
        let one = ShelfStore.removals(from: items(agedDays: [0, 1]), capacity: 1, maxAge: nil, now: t0)
        #expect(one.trashedCount == 1)
        #expect(one.title == "Move 1 file from the shelf to the Trash?")
        #expect(one.confirmLabel == "Move to Trash")

        let three = ShelfStore.removals(from: items(agedDays: [0, 1, 2, 3]), capacity: 1, maxAge: nil, now: t0)
        #expect(three.title == "Move 3 files from the shelf to the Trash?")
    }

    /// A reference leaves the list and keeps its file, so a change that
    /// takes only references must not claim anything goes to the Trash.
    @Test func referencesAreNotCalledMovesToTheTrash() {
        let listed = items(agedDays: [0, 1, 2], owned: false)
        let removed = ShelfStore.removals(from: listed, capacity: 1, maxAge: nil, now: t0)
        #expect(removed.count == 2)
        #expect(removed.trashedCount == 0)
        #expect(removed.title == "Remove 2 items from the shelf?")
        #expect(removed.confirmLabel == "Remove")
    }

    @Test func aMixedRemovalSaysWhatStaysPut() {
        let listed = items(agedDays: [0, 1]) + items(agedDays: [2], owned: false)
        let removed = ShelfStore.removals(from: listed, capacity: 1, maxAge: nil, now: t0)
        #expect(removed.title == "Move 1 file from the shelf to the Trash?")
        #expect(removed.message.contains("1 linked item also leaves the shelf"))
    }

    // MARK: - On the store

    /// **Asking changes nothing.** The whole point of the preview is that
    /// Cancel can follow it.
    @Test func previewingHasNoSideEffects() throws {
        let trash = SandboxTrash()
        let store = try trash.store()
        for i in 0..<5 { try store.add(.text("item \(i)"), now: t0.addingTimeInterval(Double(i))) }
        let before = store.items

        let removed = store.previewLimits(capacity: 2, maxAge: ShelfExpiry.oneDay.maxAge, now: t0.addingTimeInterval(9 * day))

        #expect(removed.count == 5)
        #expect(store.items == before)
        #expect(store.capacity == ShelfStore.defaultCapacity)
        #expect(store.maxAge == ShelfStore.defaultMaxAge)
        #expect(trash.trashed.isEmpty)
        #expect(before.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) })
    }

    /// The preview and the change agree: what was counted is what goes.
    @Test func thePreviewMatchesWhatSetLimitsRemoves() throws {
        let trash = SandboxTrash()
        let store = try trash.store()
        for i in 0..<6 { try store.add(.text("item \(i)"), now: t0.addingTimeInterval(Double(i) * day)) }
        let now = t0.addingTimeInterval(6 * day)

        let removed = store.previewLimits(capacity: 4, maxAge: 3 * day, now: now)
        let before = Set(store.items.map(\.id))
        store.setLimits(capacity: 4, maxAge: 3 * day, now: now)
        let gone = before.subtracting(store.items.map(\.id))

        #expect(Set(removed.items.map(\.id)) == gone)
        #expect(trash.trashed.count == removed.trashedCount)
    }

    /// **Stuck-agnostic.** The preview cannot know a file will refuse the
    /// Trash, and does not try: it names what the rule targets, by list
    /// order. Eviction skips a stuck file for the next oldest, so the *count*
    /// still matches what confirming moves — which is the number the
    /// confirmation shows.
    @Test func aStuckFileDoesNotChangeTheCountForCapacity() throws {
        let trash = SandboxTrash()
        let store = try trash.store()
        for i in 0..<5 { try store.add(.text("item \(i)"), now: t0.addingTimeInterval(Double(i))) }
        let oldest = try #require(store.items.last)
        trash.refuse(oldest.url)

        let removed = store.previewLimits(capacity: 3, maxAge: nil, now: t0)
        #expect(removed.items.contains { $0.id == oldest.id })

        store.setLimits(capacity: 3, maxAge: nil, now: t0)
        #expect(trash.trashed.count == removed.count)
        #expect(store.items.contains { $0.id == oldest.id })
    }
}

/// A `FileManager` whose Trash is a temporary directory.
///
/// `trashItem` is the one call that would reach the user's real `~/.Trash`;
/// here it moves into a directory the test owns, and can be told to refuse a
/// file to stand in for one that is locked.
final class SandboxTrash: FileManager, @unchecked Sendable {
    let root: URL
    private let bin: URL
    private(set) var trashed: [URL] = []
    private var refused: Set<String> = []

    override init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CreativeNotchSandboxTrash-\(UUID().uuidString)")
        bin = root.appendingPathComponent("Trash")
        super.init()
        try? createDirectory(at: bin, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    @MainActor
    func store(capacity: Int = ShelfStore.defaultCapacity) throws -> ShelfStore {
        try ShelfStore(directory: root.appendingPathComponent("Shelf"), fileManager: self, capacity: capacity)
    }

    func refuse(_ url: URL) { refused.insert(url.standardizedFileURL.path) }

    override func trashItem(at url: URL, resultingItemURL outResultingURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
        guard !refused.contains(url.standardizedFileURL.path) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let destination = bin.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
        try moveItem(at: url, to: destination)
        trashed.append(destination)
        outResultingURL?.pointee = destination as NSURL
    }
}
