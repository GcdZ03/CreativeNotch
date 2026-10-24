import Foundation

/// One verb a shelf tile offers outside hover: in its context menu and as a
/// VoiceOver action.
///
/// In Core, not beside the view, so the order and the rule that a copying
/// item offers nothing are pinned without SwiftUI — neither the menu nor the
/// actions are reachable from a test once rendered. The UI maps each case to
/// a closure; it never decides which verbs exist.
public enum ShelfTileVerb: CaseIterable, Equatable, Sendable {
    case open
    case quickLook
    case reveal
    case airDrop
    case remove

    /// The verbs `item` offers, in menu order: Open first, as Finder puts
    /// it; Quick Look beside it; Show in Finder and AirDrop; Remove last,
    /// where the destructive verb sits in the title row too.
    ///
    /// None while the item is still copying in: every one of them needs the
    /// file, and there is no file yet.
    public static func verbs(for item: ShelfItem) -> [ShelfTileVerb] {
        guard ShelfSelection.isSelectable(item) else { return [] }
        return allCases
    }

    public var label: String {
        switch self {
        case .open:      return "Open"
        case .quickLook: return "Quick Look"
        case .reveal:    return "Show in Finder"
        case .airDrop:   return "AirDrop"
        case .remove:    return "Remove"
        }
    }

    /// The SF Symbol beside the label in the context menu.
    public var symbolName: String {
        switch self {
        case .open:      return "arrow.up.forward.app"
        case .quickLook: return "eye"
        case .reveal:    return "folder"
        case .airDrop:   return "dot.radiowaves.left.and.right"
        case .remove:    return "xmark"
        }
    }

    public var isDestructive: Bool { self == .remove }
}

/// What Quick Look is handed: the files it may page through and where to
/// start.
public struct ShelfPreviewRequest: Equatable, Sendable {
    public let urls: [URL]
    public let index: Int

    public init(urls: [URL], index: Int) {
        self.urls = urls
        self.index = index
    }

    /// The file shown first.
    public var current: URL { urls[index] }
}

public enum ShelfPreview {
    /// The preview for `id` on a shelf holding `items`, or `nil` when there
    /// is nothing to show.
    ///
    /// **Every ready item, not just the chosen one,** so the arrow keys in
    /// Quick Look walk the shelf the way they walk a Finder folder. A file
    /// still copying in is left out of the walk, and choosing one previews
    /// nothing: its URL names a file that does not exist yet.
    ///
    /// No choice — or one whose item has since gone — starts at the first
    /// ready file, so Space on a shelf nobody has clicked into still shows
    /// something.
    public static func request(for id: UUID?, in items: [ShelfItem]) -> ShelfPreviewRequest? {
        if let id, let chosen = items.first(where: { $0.id == id }), !ShelfSelection.isSelectable(chosen) {
            return nil
        }
        let ready = items.filter(ShelfSelection.isSelectable)
        guard !ready.isEmpty else { return nil }
        let index = id.flatMap { id in ready.firstIndex { $0.id == id } } ?? 0
        return ShelfPreviewRequest(urls: ready.map(\.url), index: index)
    }
}

/// The shelf's selection: the tile Space previews and the arrow keys move.
public enum ShelfSelection {
    /// Only an item with a file behind it. The selection is what Space and
    /// Open act on, and neither can act on a copy in progress.
    public static func isSelectable(_ item: ShelfItem) -> Bool {
        !item.isPending
    }

    /// The selection after an arrow press moving `step` tiles from
    /// `current`, over the selectable items in shelf order.
    ///
    /// It stops at either end rather than wrapping, as Finder's icon view
    /// does: wrapping would jump to a tile scrolled out of sight. With
    /// nothing selected — or a selection whose item has gone — the first
    /// press picks the end it points away from, so → starts at the left.
    public static func moved(from current: UUID?, by step: Int, in items: [ShelfItem]) -> UUID? {
        let ready = items.filter(isSelectable)
        guard !ready.isEmpty else { return nil }
        guard let current, let index = ready.firstIndex(where: { $0.id == current }) else {
            return step < 0 ? ready.last?.id : ready.first?.id
        }
        let next = min(max(index + step, 0), ready.count - 1)
        return ready[next].id
    }
}
