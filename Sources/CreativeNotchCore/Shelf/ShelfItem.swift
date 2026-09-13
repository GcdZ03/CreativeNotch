import Foundation

/// One thing sitting on the shelf.
public struct ShelfItem: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let url: URL
    public let displayName: String
    public let addedAt: Date

    /// Whether the shelf owns the file behind this item.
    ///
    /// **Owned** is the original case and the default: `url` points into the
    /// shelf's own storage, a copy the shelf made, and the shelf may trash it
    /// when the item is removed, expires, or is evicted. The original the user
    /// dragged in can be moved or deleted freely.
    ///
    /// **A reference** points at a file somewhere the user cares about -- a
    /// camera capture in `~/Pictures`, which is the only copy of something
    /// they just made. Removing the item removes it from the shelf **and
    /// leaves the file alone**.
    ///
    /// This distinction is the whole of what stops the shelf's own retention
    /// rules -- seven days, twenty items, both enforced by moving files to the
    /// Trash -- from deleting a photograph the user took.
    public let isOwned: Bool

    public init(
        id: UUID,
        url: URL,
        displayName: String,
        addedAt: Date,
        isOwned: Bool = true
    ) {
        self.id = id
        self.url = url
        self.displayName = displayName
        self.addedAt = addedAt
        self.isOwned = isOwned
    }
}
