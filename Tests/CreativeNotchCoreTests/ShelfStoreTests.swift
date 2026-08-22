import Foundation
import Testing
@testable import CreativeNotchCore

/// Tested against real temporary directories rather than a fake
/// `FileManager`: name collisions, extensions and deletion are precisely
/// where a fake diverges from the real thing, and those are the cases that
/// can lose a file.
@MainActor
struct ShelfStoreTests {

    private func makeStore() throws -> (ShelfStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shelf-\(UUID().uuidString)")
        return (try ShelfStore(directory: dir), dir)
    }

    private func makeSourceFile(named name: String, contents: String = "x") throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func aNewStoreIsEmptyAndCreatesItsDirectory() throws {
        let (store, dir) = try makeStore()
        #expect(store.items.isEmpty)
        #expect(FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func addingAFileCopiesItAndLeavesTheOriginalAlone() throws {
        let (store, dir) = try makeStore()
        let source = try makeSourceFile(named: "notes.txt", contents: "hello")

        let item = try store.add(.file(source), now: t0)

        #expect(item.displayName == "notes.txt")
        #expect(item.url.deletingLastPathComponent().path == dir.path)
        #expect(try String(contentsOf: item.url, encoding: .utf8) == "hello")
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(store.items.count == 1)
    }

    @Test func theNewestItemIsFirst() throws {
        let (store, _) = try makeStore()
        try store.add(.text("one"), now: t0)
        try store.add(.text("two"), now: t0.addingTimeInterval(1))

        #expect(store.items.count == 2)
        #expect(store.items.first?.addedAt == t0.addingTimeInterval(1))
    }

    @Test func aCollidingNameGetsASuffixRatherThanOverwriting() throws {
        let (store, _) = try makeStore()
        let a = try makeSourceFile(named: "shot.png", contents: "first")
        let b = try makeSourceFile(named: "shot.png", contents: "second")
        let c = try makeSourceFile(named: "shot.png", contents: "third")

        let i1 = try store.add(.file(a), now: t0)
        let i2 = try store.add(.file(b), now: t0)
        let i3 = try store.add(.file(c), now: t0)

        #expect(i1.url.lastPathComponent == "shot.png")
        #expect(i2.url.lastPathComponent == "shot 2.png")
        #expect(i3.url.lastPathComponent == "shot 3.png")
        #expect(try String(contentsOf: i1.url, encoding: .utf8) == "first")
        #expect(try String(contentsOf: i2.url, encoding: .utf8) == "second")
        #expect(try String(contentsOf: i3.url, encoding: .utf8) == "third")
    }

    @Test func textIsWrittenAsAFile() throws {
        let (store, _) = try makeStore()
        let item = try store.add(.text("some notes"), now: t0)
        #expect(item.url.lastPathComponent == "Dropped Text.txt")
        #expect(try String(contentsOf: item.url, encoding: .utf8) == "some notes")
    }

    @Test func anImageIsWrittenWithItsExtension() throws {
        let (store, _) = try makeStore()
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])
        let item = try store.add(.image(bytes, ext: "png"), now: t0)
        #expect(item.url.lastPathComponent == "Dropped Image.png")
        #expect(try Data(contentsOf: item.url) == bytes)
    }

    @Test func theTwentyFirstItemEvictsTheOldest() throws {
        let (store, _) = try makeStore()
        var first: ShelfItem?
        for i in 0..<20 {
            let item = try store.add(.text("item \(i)"), now: t0.addingTimeInterval(Double(i)))
            if i == 0 { first = item }
        }
        #expect(store.items.count == 20)

        try store.add(.text("one too many"), now: t0.addingTimeInterval(100))

        #expect(store.items.count == 20)
        #expect(store.items.contains { $0.id == first?.id } == false)
        #expect(FileManager.default.fileExists(atPath: first!.url.path) == false)
    }

    @Test func removingTakesItOutOfTheListAndOffDisk() throws {
        let (store, _) = try makeStore()
        let item = try store.add(.text("bye"), now: t0)
        try store.remove(item.id)
        #expect(store.items.isEmpty)
        #expect(FileManager.default.fileExists(atPath: item.url.path) == false)
    }

    @Test func clearingEmptiesEverything() throws {
        let (store, _) = try makeStore()
        for i in 0..<3 { try store.add(.text("\(i)"), now: t0) }
        try store.clear()
        #expect(store.items.isEmpty)
    }

    // MARK: - Purging and persistence

    @Test func purgingRemovesItemsOlderThanSevenDays() throws {
        let (store, _) = try makeStore()
        let old = try store.add(.text("ancient"), now: t0)
        let fresh = try store.add(.text("recent"), now: t0.addingTimeInterval(ShelfStore.maxAge))

        let removed = try store.purge(now: t0.addingTimeInterval(ShelfStore.maxAge + 1))

        #expect(removed.count == 1)
        #expect(removed.first?.id == old.id)
        #expect(store.items.map(\.id) == [fresh.id])
        #expect(FileManager.default.fileExists(atPath: old.url.path) == false)
    }

    /// Exactly at the boundary the item survives; a second later it does
    /// not. Without this, `<` and `<=` are indistinguishable.
    @Test func anItemExactlyAtTheAgeLimitSurvives() throws {
        let (store, _) = try makeStore()
        try store.add(.text("borderline"), now: t0)

        #expect(try store.purge(now: t0.addingTimeInterval(ShelfStore.maxAge)).isEmpty)
        #expect(store.items.count == 1)

        #expect(try store.purge(now: t0.addingTimeInterval(ShelfStore.maxAge + 1)).count == 1)
        #expect(store.items.isEmpty)
    }

    @Test func purgingAnEmptyShelfIsHarmless() throws {
        let (store, _) = try makeStore()
        #expect(try store.purge(now: t0).isEmpty)
    }

    @Test func aShelfSurvivesBeingReopened() throws {
        let (store, dir) = try makeStore()
        try store.add(.text("kept"), now: t0)
        try store.add(.text("also kept"), now: t0.addingTimeInterval(1))

        let reopened = try ShelfStore(directory: dir)

        #expect(reopened.items.count == 2)
    }

    /// Reload sorts by creation date, newest first.
    ///
    /// The dates are stamped explicitly rather than relying on two files
    /// written milliseconds apart: at filesystem timestamp resolution that
    /// ordering is not guaranteed, and a flaky test is worse than none.
    @Test func reopeningPutsTheNewestFirst() throws {
        let (store, dir) = try makeStore()
        let older = try store.add(.text("older"), now: t0)
        let newer = try store.add(.text("newer"), now: t0)

        try FileManager.default.setAttributes(
            [.creationDate: t0], ofItemAtPath: older.url.path)
        try FileManager.default.setAttributes(
            [.creationDate: t0.addingTimeInterval(3600)], ofItemAtPath: newer.url.path)

        let reopened = try ShelfStore(directory: dir)

        #expect(reopened.items.count == 2)
        #expect(reopened.items.first?.url.lastPathComponent == newer.url.lastPathComponent)
        #expect(reopened.items.last?.url.lastPathComponent == older.url.lastPathComponent)
    }

    @Test func reopeningIgnoresFilesThatVanished() throws {
        let (store, dir) = try makeStore()
        let item = try store.add(.text("doomed"), now: t0)
        try FileManager.default.removeItem(at: item.url)

        let reopened = try ShelfStore(directory: dir)
        #expect(reopened.items.isEmpty)
    }

    @Test func theCapAndAgeAreWhatTheSpecSays() {
        #expect(ShelfStore.capacity == 20)
        #expect(ShelfStore.maxAge == 7 * 24 * 3600)
    }
}
