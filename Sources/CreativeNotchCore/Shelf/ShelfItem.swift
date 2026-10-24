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

    /// Whether the file is still being copied in.
    ///
    /// A dropped file is listed the moment the drop is accepted, under the
    /// name it has reserved, and copied off the main actor. Until the copy
    /// lands `url` names a file that does not exist yet: a pending item
    /// cannot be dragged out or AirDropped, and the shelf's removals --
    /// remove, clear, eviction, the age purge, the missing-file prune --
    /// all pass it by.
    public let isPending: Bool

    public init(
        id: UUID,
        url: URL,
        displayName: String,
        addedAt: Date,
        isOwned: Bool = true,
        isPending: Bool = false
    ) {
        self.id = id
        self.url = url
        self.displayName = displayName
        self.addedAt = addedAt
        self.isOwned = isOwned
        self.isPending = isPending
    }
}
