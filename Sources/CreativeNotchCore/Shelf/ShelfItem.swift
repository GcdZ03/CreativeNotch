import Foundation

/// One thing sitting on the shelf.
///
/// `url` points into the shelf's own storage, never at where the file came
/// from — the original may be moved or deleted freely.
public struct ShelfItem: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let url: URL
    public let displayName: String
    public let addedAt: Date

    public init(id: UUID, url: URL, displayName: String, addedAt: Date) {
        self.id = id
        self.url = url
        self.displayName = displayName
        self.addedAt = addedAt
    }
}
