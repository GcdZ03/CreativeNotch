import Foundation
import Testing
@testable import CreativeNotchCore

/// Pinning an entry: it stays at the top, outlives the ring's limits and a
/// Clear, and there can only be a few of them.
@MainActor
struct ClipboardPinTests {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func date(_ offset: TimeInterval) -> Date {
        t0.addingTimeInterval(offset)
    }

    private func texts(_ store: ClipboardStore) -> [String] {
        store.entries.map {
            if case .text(let s) = $0.content { return s }
            return "<image>"
        }
    }

    /// Records "a", "b", "c" — so the ring reads c, b, a.
    private func abc(capacity: Int = ClipboardStore.defaultCapacity) -> ClipboardStore {
        let store = ClipboardStore(capacity: capacity)
        store.record(.text("a"), now: date(0))
        store.record(.text("b"), now: date(1))
        store.record(.text("c"), now: date(2))
        return store
    }

    private func id(_ text: String, in store: ClipboardStore) throws -> UUID {
        try #require(store.entries.first { $0.content == .text(text) }).id
    }

    // MARK: - Order

    @Test func pinningMovesTheEntryToTheTop() throws {
        let store = abc()
        #expect(try store.pin(id("a", in: store)) == .pinned)
        #expect(texts(store) == ["a", "c", "b"])
        #expect(store.entries.first?.isPinned == true)
    }

    @Test func aNewCopyLandsBelowThePins() throws {
        let store = abc()
        try store.pin(id("a", in: store))
        store.record(.text("d"), now: date(3))
        #expect(texts(store) == ["a", "d", "c", "b"])
    }

    /// The latest pin goes on top, the way the latest copy does below.
    @Test func theLatestPinIsOnTop() throws {
        let store = abc()
        try store.pin(id("a", in: store))
        try store.pin(id("b", in: store))
        #expect(texts(store) == ["b", "a", "c"])
    }

    /// Unpinned, an entry goes back where its time puts it among the rest,
    /// so the unpinned part of the list always reads newest first.
    @Test func unpinningReturnsTheEntryToItsPlaceInTime() throws {
        let store = abc()
        let b = try id("b", in: store)
        store.pin(b)
        #expect(texts(store) == ["b", "c", "a"])
        store.unpin(b)
        #expect(texts(store) == ["c", "b", "a"])
        #expect(store.entries.allSatisfy { !$0.isPinned })
    }

    /// Re-copying a pinned value refreshes it and keeps it pinned: copying
    /// something back out of the history is the commonest thing done to a
    /// pin, and must not quietly unpin it.
    @Test func reCopyingAPinnedEntryKeepsItPinnedAtTheTop() throws {
        let store = abc()
        try store.pin(id("a", in: store))
        try store.pin(id("b", in: store))
        store.record(.text("a"), now: date(10))
        #expect(texts(store) == ["a", "b", "c"])
        #expect(store.entries[0].isPinned)
        #expect(store.entries[0].addedAt == date(10))
    }

    @Test func pinningTwiceIsHarmless() throws {
        let store = abc()
        let a = try id("a", in: store)
        store.pin(a)
        #expect(store.pin(a) == .alreadyPinned)
        #expect(store.pinnedCount == 1)
    }

    @Test func pinningOrUnpinningAnUnknownIdIsHarmless() {
        let store = abc()
        #expect(store.pin(UUID()) == .unknown)
        store.unpin(UUID())
        #expect(texts(store) == ["c", "b", "a"])
    }

    // MARK: - The limit

    @Test func thereAreAtMostTenPins() {
        #expect(ClipboardStore.maxPinned == 10)
    }

    @Test func pinningPastTheLimitIsRefused() throws {
        let store = ClipboardStore()
        for i in 0...ClipboardStore.maxPinned {
            store.record(.text("\(i)"), now: date(TimeInterval(i)))
        }
        for i in 0..<ClipboardStore.maxPinned {
            #expect(try store.pin(id("\(i)", in: store)) == .pinned)
        }
        #expect(!store.canPin)
        let last = try id("\(ClipboardStore.maxPinned)", in: store)
        #expect(store.pin(last) == .limitReached)
        #expect(store.pinnedCount == ClipboardStore.maxPinned)
        #expect(store.entries.first { $0.id == last }?.isPinned == false)
    }

    @Test func unpinningMakesRoomForAnotherPin() throws {
        let store = abc()
        let a = try id("a", in: store)
        store.pin(a)
        #expect(store.pinnedCount == 1)
        store.unpin(a)
        #expect(store.pinnedCount == 0)
        #expect(store.canPin)
    }

    // MARK: - Exempt from eviction

    /// Pins count towards the history size but are never what it trims:
    /// the oldest *unpinned* entry goes instead.
    @Test func theCapacityTrimPassesOverPins() throws {
        let store = abc(capacity: 3)
        try store.pin(id("a", in: store))
        store.record(.text("d"), now: date(3))
        #expect(texts(store) == ["a", "d", "c"])
    }

    @Test func shrinkingTheHistoryKeepsThePins() throws {
        let store = abc()
        try store.pin(id("a", in: store))
        store.setCapacity(1)
        #expect(texts(store).contains("a"))
        #expect(store.entries.first?.isPinned == true)
    }

    /// Even with every slot pinned, the entry just copied is kept: a copy
    /// that vanished the instant it was made is the outcome
    /// `theEntryJustRecordedIsNeverEvicted` exists to prevent.
    @Test func theEntryJustRecordedSurvivesAHistoryFullOfPins() throws {
        let store = abc(capacity: 2)
        try store.pin(id("c", in: store))
        try store.pin(id("b", in: store))
        store.record(.text("d"), now: date(3))
        #expect(texts(store) == ["b", "c", "d"])
    }

    @Test func theByteBudgetPassesOverPins() throws {
        let store = ClipboardStore()
        let chunk = ClipboardLimits.maxImageBytes
        // The first image, pinned, is the oldest thing in the ring.
        store.record(.image(Data(repeating: 0, count: chunk), ext: "png"), now: date(0))
        let first = try #require(store.entries.first).id
        store.pin(first)
        let budgetInChunks = ClipboardStore.maxTotalBytes / chunk
        for i in 1...budgetInChunks {
            store.record(.image(Data(repeating: UInt8(i), count: chunk), ext: "png"), now: date(Double(i)))
        }
        #expect(store.entries.contains { $0.id == first })
        #expect(store.totalBytes <= ClipboardStore.maxTotalBytes)
    }

    // MARK: - Clear

    /// Clear sweeps the history and leaves what was pinned: a pin is the
    /// person saying "keep this", and Clear is the person sweeping away
    /// what they did not say that about.
    @Test func clearLeavesThePins() throws {
        let store = abc()
        try store.pin(id("b", in: store))
        store.clear()
        #expect(texts(store) == ["b"])
        #expect(store.entries[0].isPinned)
    }

    @Test func theClearableCountLeavesOutThePins() throws {
        let store = abc()
        #expect(store.clearableCount == 3)
        try store.pin(id("b", in: store))
        #expect(store.clearableCount == 2)
    }

    /// Switching the module off forgets everything, pins included: off
    /// means the app holds nothing.
    @Test func removeAllForgetsThePinsToo() throws {
        let store = abc()
        try store.pin(id("b", in: store))
        store.removeAll()
        #expect(store.entries.isEmpty)
        #expect(store.pinnedCount == 0)
    }

    @Test func aPinnedEntryCanStillBeRemoved() throws {
        let store = abc()
        let b = try id("b", in: store)
        store.pin(b)
        store.remove(b)
        #expect(texts(store) == ["c", "a"])
        #expect(store.pinnedCount == 0)
    }
}
