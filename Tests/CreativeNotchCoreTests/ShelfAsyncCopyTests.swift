import Foundation
import Synchronization
import Testing
@testable import CreativeNotchCore

/// A dropped file is copied off the main actor: the drop is validated and
/// answered at once, the item is listed as pending, and it turns ready when
/// the copy lands.
///
/// Every copy here goes through `GatedCopier`, so a test decides when each
/// one finishes -- and whether it fails -- without a single real sleep.
///
/// None of these tests trashes anything. The purge, eviction and clear
/// cases are built so the only candidates are pending items (which have no
/// file to trash) or the item an add spares, which is the point: before the
/// pending state existed, those calls dropped the pending tile, and still
/// touched nothing on disk.
@MainActor
struct ShelfAsyncCopyTests {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    // MARK: - Pending, then ready

    @Test func aDroppedFileIsListedAsPendingUntilItsCopyLands() async throws {
        let gate = GatedCopier()
        let (store, dir) = try makeStore(gate)
        let source = try makeSourceFile(named: "big.mov", contents: "frames")

        let item = try store.add(.file(source), now: t0)

        #expect(item.isPending)
        #expect(store.items.map(\.id) == [item.id])
        #expect(store.items.first?.isPending == true)
        #expect(!FileManager.default.fileExists(atPath: item.url.path),
                "the reserved name was written before the copy finished")

        gate.finish(source)
        await store.waitForPendingCopies()

        let ready = try #require(store.items.first)
        #expect(ready.id == item.id, "the pending tile was replaced rather than turned ready")
        #expect(!ready.isPending)
        #expect(ready.url == dir.appendingPathComponent("big.mov"))
        #expect(try String(contentsOf: ready.url, encoding: .utf8) == "frames")
        #expect(try partials(in: dir).isEmpty, "the temporary copy was left behind")
    }

    /// The drop time is stamped on the finished copy, as a synchronous add
    /// does, or the next launch reloads it with the source's creation date.
    @Test func theFinishedCopyCarriesTheDropTime() async throws {
        let gate = GatedCopier()
        let (store, dir) = try makeStore(gate)
        let source = try makeSourceFile(named: "old.txt")
        try FileManager.default.setAttributes(
            [.creationDate: t0.addingTimeInterval(-30 * 24 * 3600)],
            ofItemAtPath: source.path)

        try store.add(.file(source), now: t0)
        gate.finish(source)
        await store.waitForPendingCopies()

        let reopened = try ShelfStore(directory: dir)
        let reloaded = try #require(reopened.items.first)
        #expect(abs(reloaded.addedAt.timeIntervalSince(t0)) < 1)
    }

    /// The copy runs while the main actor is free: the store answers the
    /// drop before the copier has been allowed to do anything.
    @Test func theCopyDoesNotHoldTheMainActor() async throws {
        let gate = GatedCopier()
        let (store, _) = try makeStore(gate)
        let source = try makeSourceFile(named: "huge.bin")

        try store.add(.file(source), now: t0)
        // The main actor is still ours, with the copy parked in the gate.
        // Text drops still land in the meantime.
        let text = try store.add(.text("meanwhile"), now: t0)
        #expect(!text.isPending)
        #expect(store.items.count == 2)

        gate.finish(source)
        await store.waitForPendingCopies()
        #expect(store.items.allSatisfy { !$0.isPending })
    }

    // MARK: - Failure

    @Test func aFailedCopyRemovesThePendingItemAndReportsIt() async throws {
        let gate = GatedCopier()
        let (store, dir) = try makeStore(gate)
        let source = try makeSourceFile(named: "doomed.mov")
        var reported: [String] = []
        store.onCopyFailed = { item, _ in reported.append(item.displayName) }

        try store.add(.file(source), now: t0)
        gate.fail(source)
        await store.waitForPendingCopies()

        #expect(store.items.isEmpty)
        #expect(reported == ["doomed.mov"])
        #expect(try partials(in: dir).isEmpty, "the half-written copy was left behind")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("doomed.mov").path))
        #expect(FileManager.default.fileExists(atPath: source.path), "the original was touched")
    }

    // MARK: - Names

    /// Two drops of the same name while the first is still copying: the
    /// second must not be handed the name the first has reserved, or one
    /// rename would land on top of the other.
    @Test func twoConcurrentDropsOfOneNameGetDistinctNames() async throws {
        let gate = GatedCopier()
        let (store, _) = try makeStore(gate)
        let a = try makeSourceFile(named: "clip.mov", contents: "first")
        let b = try makeSourceFile(named: "clip.mov", contents: "second")

        let first = try store.add(.file(a), now: t0)
        let second = try store.add(.file(b), now: t0)

        #expect(first.url.lastPathComponent == "clip.mov")
        #expect(second.url.lastPathComponent == "clip 2.mov")

        // Finished out of order, which is how a slower volume would do it.
        gate.finish(b)
        gate.finish(a)
        await store.waitForPendingCopies()

        let byID = Dictionary(uniqueKeysWithValues: store.items.map { ($0.id, $0) })
        let readyFirst = try #require(byID[first.id])
        let readySecond = try #require(byID[second.id])
        #expect(try String(contentsOf: readyFirst.url, encoding: .utf8) == "first")
        #expect(try String(contentsOf: readySecond.url, encoding: .utf8) == "second")
    }

    /// A text drop arriving mid-copy is a synchronous write and must not
    /// take a pending item's reserved name either.
    @Test func aTextDropDoesNotTakeAReservedName() throws {
        let gate = GatedCopier()
        let (store, _) = try makeStore(gate)
        let source = try makeSourceFile(named: "Dropped Text.txt")

        let pending = try store.add(.file(source), now: t0)
        let text = try store.add(.text("hello"), now: t0)

        #expect(pending.url.lastPathComponent == "Dropped Text.txt")
        #expect(text.url.lastPathComponent == "Dropped Text 2.txt")
    }

    // MARK: - Housekeeping never touches a pending item

    @Test func thePurgeSkipsAPendingItem() throws {
        let gate = GatedCopier()
        let (store, _) = try makeStore(gate)
        let source = try makeSourceFile(named: "slow.mov")
        let pending = try store.add(.file(source), now: t0)

        let removed = try store.purge(now: t0.addingTimeInterval(365 * 24 * 3600))

        #expect(removed.isEmpty)
        #expect(store.items.map(\.id) == [pending.id])
    }

    /// Pending items count toward the capacity but are never evicted: the
    /// copy is still running, and there is no file to put in the Trash.
    @Test func evictionSkipsAPendingItem() throws {
        let gate = GatedCopier()
        let dir = makeDirectoryURL()
        let store = try ShelfStore(directory: dir, capacity: 1, copier: gate.copier)
        let source = try makeSourceFile(named: "slow.mov")
        let pending = try store.add(.file(source), now: t0)

        // Over capacity: the only candidate is the pending item, and the
        // text is the item just added, which is spared.
        let text = try store.add(.text("newer"), now: t0.addingTimeInterval(1))

        #expect(Set(store.items.map(\.id)) == [pending.id, text.id])
    }

    @Test func clearLeavesAPendingItemListed() throws {
        let gate = GatedCopier()
        let (store, _) = try makeStore(gate)
        let source = try makeSourceFile(named: "slow.mov")
        let pending = try store.add(.file(source), now: t0)

        let clearance = try store.clear()

        #expect(clearance.isEmpty)
        #expect(store.items.map(\.id) == [pending.id])
    }

    @Test func removeAndPruneLeaveAPendingItemListed() throws {
        let gate = GatedCopier()
        let (store, _) = try makeStore(gate)
        let source = try makeSourceFile(named: "slow.mov")
        let pending = try store.add(.file(source), now: t0)

        try store.remove(pending.id)
        // Its reserved name has no file yet; that is not "missing".
        store.pruneMissing()

        #expect(store.items.map(\.id) == [pending.id])
    }

    /// AirDrop and the pane's whole-shelf verbs read only the items that
    /// have a file behind them.
    @Test func readyItemsLeaveOutPendingOnes() throws {
        let gate = GatedCopier()
        let (store, _) = try makeStore(gate)
        let source = try makeSourceFile(named: "slow.mov")
        try store.add(.file(source), now: t0)
        let text = try store.add(.text("done"), now: t0)

        #expect(store.readyItems.map(\.id) == [text.id])
    }

    // MARK: - Launch

    /// A quit mid-copy leaves a hidden partial behind. It is not an item,
    /// so nothing else would ever clear it.
    @Test func stalePartialsAreRemovedOnLoad() throws {
        let dir = makeDirectoryURL()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stale = dir.appendingPathComponent(".\(UUID().uuidString).partial")
        try Data("half".utf8).write(to: stale)
        try Data("kept".utf8).write(to: dir.appendingPathComponent("kept.txt"))

        let store = try ShelfStore(directory: dir)

        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(store.items.map(\.displayName) == ["kept.txt"])
    }

    // MARK: - Refused at drop time

    @Test func aMissingSourceIsRefusedAtOnce() throws {
        let gate = GatedCopier()
        let (store, _) = try makeStore(gate)
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gone-\(UUID().uuidString).txt")

        #expect(throws: ShelfStore.AddError.self) {
            try store.add(.file(missing), now: t0)
        }
        #expect(store.items.isEmpty)
    }

    @Test func aFileLargerThanTheFreeSpaceIsRefusedAtOnce() throws {
        let gate = GatedCopier(availableCapacity: 3)
        let (store, _) = try makeStore(gate)
        let source = try makeSourceFile(named: "big.bin", contents: "more than three bytes")

        #expect(throws: ShelfStore.AddError.self) {
            try store.add(.file(source), now: t0)
        }
        #expect(store.items.isEmpty)
    }

    /// Spec section 9 for files: a shelf directory that cannot be written is
    /// known at drop time, so the drop is refused rather than accepted and
    /// failed a moment later.
    @Test func aFileDropOntoAnUnwritableShelfIsRefusedAtOnce() throws {
        let gate = GatedCopier()
        let (store, dir) = try makeStore(gate)
        let source = try makeSourceFile(named: "notes.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        }

        #expect(throws: ShelfStore.AddError.self) {
            try store.add(.file(source), now: t0)
        }
        #expect(store.items.isEmpty)
    }

    /// A folder is not walked at drop time -- that could be the slow part --
    /// so it is accepted and copied like a file.
    @Test func aFolderIsAcceptedWithoutBeingMeasured() async throws {
        let gate = GatedCopier(availableCapacity: 0)
        let (store, _) = try makeStore(gate)
        let folder = try makeSourceFile(named: "inner.txt", contents: "x").deletingLastPathComponent()

        let item = try store.add(.file(folder), now: t0)
        #expect(item.isPending)

        gate.finish(folder)
        await store.waitForPendingCopies()
        let ready = try #require(store.items.first)
        #expect(!ready.isPending)
        #expect(FileManager.default.fileExists(atPath: ready.url.appendingPathComponent("inner.txt").path))
    }

    // MARK: - Helpers

    private func makeDirectoryURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shelf-\(UUID().uuidString)")
    }

    private func makeStore(_ gate: GatedCopier) throws -> (ShelfStore, URL) {
        let dir = makeDirectoryURL()
        return (try ShelfStore(directory: dir, copier: gate.copier), dir)
    }

    private func makeSourceFile(named name: String, contents: String = "x") throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func partials(in dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".partial") }
    }
}

/// A copier whose copies finish only when the test says so.
///
/// `finish` and `fail` may arrive before the copy has even started -- the
/// copy runs in a `Task` -- so an early answer is kept and handed over when
/// the copy asks for it.
final class GatedCopier: Sendable {

    private enum Outcome: Sendable { case finish, fail }

    private struct State {
        var outcomes: [URL: Outcome] = [:]
        var waiting: [URL: CheckedContinuation<Outcome, Never>] = [:]
    }

    private let state = Mutex(State())
    private let capacity: Int64?

    init(availableCapacity: Int64? = nil) {
        self.capacity = availableCapacity
    }

    struct Failure: Error {}

    var copier: ShelfCopier {
        ShelfCopier(
            copy: { [self] source, destination in
                switch await self.outcome(for: source) {
                case .finish:
                    try FileManager.default.copyItem(at: source, to: destination)
                case .fail:
                    // Half a file, as a copy cut off part-way leaves.
                    try Data("half".utf8).write(to: destination)
                    throw Failure()
                }
            },
            availableCapacity: { [capacity] _ in capacity }
        )
    }

    func finish(_ source: URL) { resolve(source, .finish) }
    func fail(_ source: URL) { resolve(source, .fail) }

    private func resolve(_ source: URL, _ outcome: Outcome) {
        let continuation = state.withLock { state -> CheckedContinuation<Outcome, Never>? in
            if let waiting = state.waiting.removeValue(forKey: source) { return waiting }
            state.outcomes[source] = outcome
            return nil
        }
        continuation?.resume(returning: outcome)
    }

    private func outcome(for source: URL) async -> Outcome {
        await withCheckedContinuation { continuation in
            let early = state.withLock { state -> Outcome? in
                if let outcome = state.outcomes.removeValue(forKey: source) { return outcome }
                state.waiting[source] = continuation
                return nil
            }
            if let early { continuation.resume(returning: early) }
        }
    }
}
