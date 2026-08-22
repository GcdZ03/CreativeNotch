import AppKit
import QuickLookThumbnailing

/// QuickLook previews with a file-icon fallback.
///
/// The cache needs no eviction policy of its own: the shelf holds at most
/// twenty items, so it is bounded by the store.
@MainActor
final class ShelfThumbnails {

    static let shared = ShelfThumbnails()

    private var cache: [URL: NSImage] = [:]

    /// The system icon — correct for every file type including folders and
    /// app bundles, and available immediately, unlike a preview.
    func icon(for url: URL) -> NSImage {
        NSWorkspace.shared.icon(forFile: url.path)
    }

    func thumbnail(for url: URL, size: CGSize) async -> NSImage {
        if let hit = cache[url] { return hit }

        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: 2,
            representationTypes: .thumbnail
        )

        if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            cache[url] = rep.nsImage
            return rep.nsImage
        }

        let fallback = icon(for: url)
        cache[url] = fallback
        return fallback
    }

    func forget(_ url: URL) { cache[url] = nil }
}
