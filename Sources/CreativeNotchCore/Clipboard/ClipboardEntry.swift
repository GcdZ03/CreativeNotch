import Foundation

/// One slot in the clipboard ring.
///
/// `addedAt` is a `var` because promotion refreshes it: an entry sitting at
/// the front because it was just re-copied would otherwise show a
/// timestamp from the first time it was seen, contradicting the order the
/// list is displayed in.
///
/// `id` survives promotion. The view is a `ForEach` over `Identifiable`,
/// and a fresh id would animate a move as a delete plus an insert.
public struct ClipboardEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let content: ClipboardContent
    public var addedAt: Date

    public init(id: UUID, content: ClipboardContent, addedAt: Date) {
        self.id = id
        self.content = content
        self.addedAt = addedAt
    }
}
