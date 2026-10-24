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
///
/// `isPinned` lives on the entry rather than in a set of ids beside the
/// ring, so an entry and its pin cannot come apart: removing one removes
/// the other, and nothing has to be kept in step. Like the rest of the
/// entry it is never written down (see `ClipboardStore`).
public struct ClipboardEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let content: ClipboardContent
    public var addedAt: Date
    public var isPinned: Bool

    public init(id: UUID, content: ClipboardContent, addedAt: Date, isPinned: Bool = false) {
        self.id = id
        self.content = content
        self.addedAt = addedAt
        self.isPinned = isPinned
    }
}
