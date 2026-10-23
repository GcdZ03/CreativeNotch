import AppKit
import CreativeNotchCore
import QuickLookThumbnailing

/// QuickLook previews with a file-icon fallback.
///
/// The cache needs no eviction policy of its own: it is keyed by URL, and
/// the shelf reuses the lowest free name in its directory, so the set of
/// URLs is bounded by the store.
///
/// That reuse is also why each entry remembers *which item* it was drawn
/// for. Remove "Dropped Image.png", drop another image, and the new file
/// lands at the very same URL; keyed by URL alone, its tile showed the
/// previous image. An entry for a different item ID is redrawn rather
/// than served -- so no invalidation call has to reach the cache from
/// every path that removes an item, including the store's own eviction
/// and purge, which the UI never hears about.
@MainActor
final class ShelfThumbnails {

    static let shared = ShelfThumbnails()

    typealias Renderer = @MainActor (URL, CGSize) async -> NSImage

    private var cache: [URL: (item: ShelfItem.ID, image: NSImage)] = [:]
    private let render: Renderer

    /// `render` is replaceable so tests can count how often the cache is
    /// bypassed without depending on what QuickLook draws.
    init(render: Renderer? = nil) {
        self.render = render ?? { url, size in await Self.quickLook(url, size: size) }
    }

    /// The system icon — correct for every file type including folders and
    /// app bundles, and available immediately, unlike a preview.
    func icon(for url: URL) -> NSImage {
        NSWorkspace.shared.icon(forFile: url.path)
    }

    func thumbnail(for item: ShelfItem, size: CGSize) async -> NSImage {
        if let hit = cache[item.url], hit.item == item.id { return hit.image }

        let image = await render(item.url, size)
        cache[item.url] = (item.id, image)
        return image
    }

    private static func quickLook(_ url: URL, size: CGSize) async -> NSImage {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: 2,
            representationTypes: .thumbnail
        )

        if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            return rep.nsImage
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
