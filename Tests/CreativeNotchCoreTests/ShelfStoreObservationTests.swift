import Foundation
import Observation
import Testing
@testable import CreativeNotchCore

/// `ShelfView` reads `store.items` in its body and holds the store as a
/// plain `let`. Without `@Observable` on the store, SwiftUI has no way to
/// learn that `items` changed.
///
/// The bug that hides this: every *drop* is followed by
/// `state.transition(to: .open(.shelf))`, and `AppState` is observable —
/// so the view is rebuilt by the state change and appears to track the
/// store. The menu bar's "Clear Shelf" performs no transition, so an open
/// shelf keeps showing items whose files are already in the Trash.
///
/// `withObservationTracking` is the same mechanism SwiftUI uses, so this
/// tests the real question rather than a proxy for it.
@MainActor
struct ShelfStoreObservationTests {

    /// `onChange` is `@Sendable`, so a captured `var` cannot be mutated
    /// from it. A reference box is the usual way around that in a test.
    private final class Flag: @unchecked Sendable {
        var value = false
    }

    private func makeStore() throws -> ShelfStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CreativeNotchShelfObs-\(UUID().uuidString)")
        return try ShelfStore(directory: directory)
    }

    @Test func addingAnItemNotifiesObservers() throws {
        let store = try makeStore()
        let flag = Flag()

        withObservationTracking {
            _ = store.items
        } onChange: {
            flag.value = true
        }

        try store.add(.text("hello"), now: Date())

        #expect(flag.value, "a shelf view reading items must be told when one is added")
    }

    /// The path with no accompanying state transition — the one that is
    /// visibly broken today.
    @Test func clearingNotifiesObservers() throws {
        let store = try makeStore()
        try store.add(.text("hello"), now: Date())

        let flag = Flag()
        withObservationTracking {
            _ = store.items
        } onChange: {
            flag.value = true
        }

        try store.clear()

        #expect(flag.value, "clearing from the menu bar must refresh an open shelf")
    }

    @Test func removingAnItemNotifiesObservers() throws {
        let store = try makeStore()
        let item = try store.add(.text("hello"), now: Date())

        let flag = Flag()
        withObservationTracking {
            _ = store.items
        } onChange: {
            flag.value = true
        }

        try store.remove(item.id)

        #expect(flag.value)
    }
}
