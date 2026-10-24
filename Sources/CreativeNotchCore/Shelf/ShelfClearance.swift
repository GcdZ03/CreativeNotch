import Foundation

/// What a `ShelfStore.clear()` took off the shelf, and where each file went
/// -- everything `ShelfStore.restore(_:)` needs to put it back.
///
/// A value rather than state kept inside the store: how long an undo stays
/// on offer is a UI decision, and the store should not be the thing that
/// remembers a clear the user can no longer see a way to undo.
public struct ShelfClearance: Equatable, Sendable {

    public struct Entry: Equatable, Sendable {
        /// The item as it was listed, with its original URL and drop time.
        public let item: ShelfItem

        /// Where the shelf's `ShelfTrash` put an owned file.
        ///
        /// `nil` for a reference, which was never moved, and for an owned
        /// file that was already gone when the shelf was cleared -- there
        /// is nothing in the Trash to bring back for that one.
        public let trashedURL: URL?

        public init(item: ShelfItem, trashedURL: URL?) {
            self.item = item
            self.trashedURL = trashedURL
        }
    }

    /// In list order, newest first.
    public let entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = entries
    }

    /// Nothing was cleared, so there is nothing to offer to undo.
    public var isEmpty: Bool { entries.isEmpty }
}

/// What `ShelfStore.restore(_:)` managed to put back.
public struct ShelfRestoration: Equatable, Sendable {
    /// Back on the shelf, as they are now listed -- an owned file whose old
    /// name was taken in the meantime carries its new, suffixed URL.
    public let restored: [ShelfItem]

    /// Could not come back: the file was emptied out of the Trash, moved,
    /// or a reference's file no longer exists where it pointed.
    public let skipped: [ShelfItem]

    public init(restored: [ShelfItem], skipped: [ShelfItem]) {
        self.restored = restored
        self.skipped = skipped
    }
}
