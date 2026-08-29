import Foundation
import Testing
@testable import CreativeNotchCore

/// Spec section 5.3: a 50-entry ring, in memory only, cleared on quit.
///
/// "Cleared on quit" is not tested here because it is not implemented
/// here — it is a consequence of this type having no persistence at all.
/// The test that guards it is `theStoreNeverTouchesTheFileSystem` below,
/// which pins the *absence* of file APIs in the source.
@MainActor
struct ClipboardStoreTests {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func date(_ offset: TimeInterval) -> Date {
        t0.addingTimeInterval(offset)
    }

    // MARK: - Recording

    @Test func aFreshStoreIsEmpty() {
        #expect(ClipboardStore().entries.isEmpty)
    }

    @Test func recordingPutsTheEntryAtTheFront() {
        let store = ClipboardStore()
        store.record(.text("first"), now: date(0))
        store.record(.text("second"), now: date(1))

        #expect(store.entries.map(\.content) == [.text("second"), .text("first")])
    }

    @Test func theRecordedEntryIsReturned() throws {
        let store = ClipboardStore()
        let entry = try #require(store.record(.text("hello"), now: date(0)))

        #expect(entry.content == .text("hello"))
        #expect(entry.addedAt == date(0))
        #expect(store.entries.first?.id == entry.id)
    }

    @Test func imagesAreRecordedToo() {
        let store = ClipboardStore()
        let data = Data(repeating: 3, count: 128)
        store.record(.image(data, ext: "png"), now: date(0))

        #expect(store.entries.map(\.content) == [.image(data, ext: "png")])
    }

    // MARK: - Limits

    /// The store applies `ClipboardLimits` as its own invariant rather than
    /// trusting its caller. The reader also checks, so it can judge an
    /// image at the size it will actually be stored at — but the ring's
    /// guarantee about what it holds has to be enforced by the ring.
    @Test func overCapContentIsRejected() {
        let store = ClipboardStore()
        let huge = String(repeating: "a", count: ClipboardLimits.maxTextBytes + 1)

        #expect(store.record(.text(huge), now: date(0)) == nil)
        #expect(store.entries.isEmpty)
    }

    @Test func blankContentIsRejected() {
        let store = ClipboardStore()
        #expect(store.record(.text("   \n"), now: date(0)) == nil)
        #expect(store.entries.isEmpty)
    }

    /// A rejected entry must not disturb what is already there.
    @Test func aRejectedEntryLeavesTheRingUntouched() {
        let store = ClipboardStore()
        store.record(.text("keeper"), now: date(0))
        store.record(.text(""), now: date(1))

        #expect(store.entries.map(\.content) == [.text("keeper")])
    }

    // MARK: - Promotion

    /// Copy A, B, then A again. The ring holds two entries, not three, and
    /// A is at the front.
    @Test func reCopyingPromotesRatherThanDuplicates() {
        let store = ClipboardStore()
        store.record(.text("A"), now: date(0))
        store.record(.text("B"), now: date(1))
        store.record(.text("A"), now: date(2))

        #expect(store.entries.map(\.content) == [.text("A"), .text("B")])
    }

    /// Promotion refreshes the timestamp: the entry is at the front
    /// *because* it was just copied, and a stale date would contradict the
    /// order the list is displayed in.
    @Test func promotionRefreshesTheTimestamp() {
        let store = ClipboardStore()
        store.record(.text("A"), now: date(0))
        store.record(.text("B"), now: date(1))
        store.record(.text("A"), now: date(2))

        #expect(store.entries.first?.addedAt == date(2))
    }

    /// Promotion keeps the original identity. The view is a `ForEach` over
    /// `Identifiable`, so a fresh id would animate as a delete plus an
    /// insert instead of a move.
    @Test func promotionKeepsTheEntryIdentity() throws {
        let store = ClipboardStore()
        let first = try #require(store.record(.text("A"), now: date(0)))
        store.record(.text("B"), now: date(1))
        let promoted = try #require(store.record(.text("A"), now: date(2)))

        #expect(promoted.id == first.id)
        #expect(store.entries.first?.id == first.id)
    }

    /// Re-copying the front entry — what the app's own paste-back produces
    /// — changes nothing but the timestamp.
    @Test func promotingTheFrontEntryIsStable() {
        let store = ClipboardStore()
        store.record(.text("A"), now: date(0))
        store.record(.text("A"), now: date(1))

        #expect(store.entries.count == 1)
        #expect(store.entries.first?.addedAt == date(1))
    }

    /// Promotion is keyed on content, so an image matches by its bytes.
    @Test func imagesPromoteByTheirBytes() {
        let store = ClipboardStore()
        let data = Data([9, 9, 9])
        store.record(.image(data, ext: "png"), now: date(0))
        store.record(.text("other"), now: date(1))
        store.record(.image(data, ext: "png"), now: date(2))

        #expect(store.entries.count == 2)
        #expect(store.entries.first?.content == .image(data, ext: "png"))
    }

    /// Fifty distinct entries followed by a re-copy of the oldest must not
    /// evict anything: promotion moves, it does not add.
    @Test func promotionNeverEvicts() {
        let store = ClipboardStore()
        for i in 0..<ClipboardStore.capacity {
            store.record(.text("entry \(i)"), now: date(TimeInterval(i)))
        }
        store.record(.text("entry 0"), now: date(999))

        #expect(store.entries.count == ClipboardStore.capacity)
        #expect(store.entries.first?.content == .text("entry 0"))
        #expect(store.entries.contains { $0.content == .text("entry 1") })
    }

    // MARK: - Capacity

    @Test func theCapacityIsWhatTheSpecSays() {
        #expect(ClipboardStore.capacity == 50)
    }

    @Test func theOldestEntryIsEvictedBeyondCapacity() {
        let store = ClipboardStore()
        for i in 0...ClipboardStore.capacity {
            store.record(.text("entry \(i)"), now: date(TimeInterval(i)))
        }

        #expect(store.entries.count == ClipboardStore.capacity)
        #expect(store.entries.first?.content == .text("entry \(ClipboardStore.capacity)"))
        #expect(store.entries.contains { $0.content == .text("entry 0") } == false)
        #expect(store.entries.last?.content == .text("entry 1"))
    }

    @Test func theRingStaysAtCapacityUnderSustainedLoad() {
        let store = ClipboardStore()
        for i in 0..<(ClipboardStore.capacity * 3) {
            store.record(.text("entry \(i)"), now: date(TimeInterval(i)))
        }

        #expect(store.entries.count == ClipboardStore.capacity)
    }

    // MARK: - The byte budget

    /// A count cap alone bounds the ring at `capacity × maxImageBytes` —
    /// 500 MB. That is the number this budget exists to replace, and it
    /// holds however well or badly anything compresses.
    @Test func theBudgetIsWhatTheSpecSays() {
        #expect(ClipboardStore.maxTotalBytes == 100_000_000)
    }

    @Test func totalBytesSumsTheRing() {
        let store = ClipboardStore()
        store.record(.text("abc"), now: date(0))
        store.record(.image(Data(repeating: 0, count: 1000), ext: "png"), now: date(1))

        #expect(store.totalBytes == 1003)
    }

    @Test func anEmptyRingCostsNothing() {
        #expect(ClipboardStore().totalBytes == 0)
    }

    /// Twenty 9 MB images is 180 MB under the count cap alone. The budget
    /// evicts oldest-first until the ring is back under it.
    @Test func theOldestEntriesAreEvictedToStayUnderBudget() {
        let store = ClipboardStore()
        let nineMB = 9_000_000

        for i in 0..<20 {
            var bytes = Data(repeating: 0, count: nineMB)
            bytes[0] = UInt8(i)   // distinct, so nothing promotes
            store.record(.image(bytes, ext: "png"), now: date(TimeInterval(i)))
        }

        #expect(store.totalBytes <= ClipboardStore.maxTotalBytes)
        #expect(store.entries.count < 20)
        // The newest survived; the oldest did not.
        #expect(store.entries.first?.content.byteCount == nineMB)
        #expect(store.entries.count == ClipboardStore.maxTotalBytes / nineMB)
    }

    /// Text never approaches the budget, so a text-only ring is governed
    /// by the count cap exactly as before.
    @Test func aTextOnlyRingIsUnaffectedByTheBudget() {
        let store = ClipboardStore()
        for i in 0..<ClipboardStore.capacity {
            store.record(.text("entry \(i)"), now: date(TimeInterval(i)))
        }

        #expect(store.entries.count == ClipboardStore.capacity)
    }

    /// The entry just copied is never the one evicted. It cannot happen
    /// while the per-entry cap is far below the budget, but a future
    /// change to either number must not turn `record` into a no-op that
    /// silently discards what the user just did.
    @Test func theEntryJustRecordedIsNeverEvicted() throws {
        let store = ClipboardStore()
        let nineMB = 9_000_000

        for i in 0..<30 {
            var bytes = Data(repeating: 0, count: nineMB)
            bytes[0] = UInt8(i)
            let entry = try #require(store.record(.image(bytes, ext: "png"), now: date(TimeInterval(i))))
            #expect(store.entries.first?.id == entry.id)
        }
    }

    // MARK: - Clearing

    @Test func clearingEmptiesTheRing() {
        let store = ClipboardStore()
        store.record(.text("A"), now: date(0))
        store.record(.text("B"), now: date(1))
        store.clear()

        #expect(store.entries.isEmpty)
    }

    @Test func clearingAnEmptyRingIsHarmless() {
        let store = ClipboardStore()
        store.clear()
        #expect(store.entries.isEmpty)
    }

    /// After clearing, the ring behaves like a fresh one — in particular a
    /// value that was there before is recorded again rather than promoted
    /// against a stale entry.
    @Test func theRingIsUsableAfterClearing() {
        let store = ClipboardStore()
        store.record(.text("A"), now: date(0))
        store.clear()
        store.record(.text("A"), now: date(1))

        #expect(store.entries.map(\.content) == [.text("A")])
    }

    // MARK: - The in-memory guarantee

    /// The strongest claim in `SECURITY.md` is that captured content never
    /// reaches disk. That is guaranteed by this type having no persistence
    /// code at all, which is a property of the source rather than of any
    /// behaviour — so it is checked by reading the source.
    ///
    /// `ShelfStore` is the counter-example living one directory away: the
    /// same shape of type, with `FileManager` throughout. Nothing but this
    /// test stops the two converging.
    @Test func theStoreNeverTouchesTheFileSystem() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // .../Tests/CreativeNotchCoreTests
            .deletingLastPathComponent()   // .../Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Sources/CreativeNotchCore/Clipboard/ClipboardStore.swift")

        let text = try String(contentsOf: source, encoding: .utf8)
        let banned = ["FileManager", "UserDefaults", "URL(fileURLWithPath", "write(to", "NSKeyedArchiver"]

        for token in banned {
            #expect(text.contains(token) == false, "ClipboardStore must stay in memory: found \(token)")
        }
    }
}
