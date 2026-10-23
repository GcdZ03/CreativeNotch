import AppKit
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// The thumbnail cache, with QuickLook replaced by a renderer that counts
/// its calls -- the question is when the cache is consulted, not what
/// QuickLook draws.
@MainActor
struct ShelfThumbnailsTests {

    private final class Counter {
        var calls = 0
    }

    private func makeThumbnails(_ counter: Counter) -> ShelfThumbnails {
        ShelfThumbnails { _, _ in
            counter.calls += 1
            return NSImage(size: CGSize(width: 1, height: 1))
        }
    }

    private let size = CGSize(width: 64, height: 64)
    private let url = URL(fileURLWithPath: "/tmp/shelf/Dropped Image.png")

    private func item(at url: URL) -> ShelfItem {
        ShelfItem(id: UUID(), url: url, displayName: url.lastPathComponent, addedAt: Date())
    }

    /// The shelf reuses a freed name: remove "Dropped Image.png", drop
    /// another image, and the new file has the old one's URL. Keyed by URL
    /// alone, the new tile showed the previous image.
    @Test func aNewItemAtAReusedURLIsRenderedAfresh() async {
        let counter = Counter()
        let thumbnails = makeThumbnails(counter)

        let first = await thumbnails.thumbnail(for: item(at: url), size: size)
        let second = await thumbnails.thumbnail(for: item(at: url), size: size)

        #expect(counter.calls == 2)
        #expect(first !== second, "a new drop showed the previous file's thumbnail")
    }

    /// The control: the same item asked twice -- every time its tile is
    /// rebuilt -- is still served from the cache.
    @Test func theSameItemIsServedFromTheCache() async {
        let counter = Counter()
        let thumbnails = makeThumbnails(counter)
        let one = item(at: url)

        let first = await thumbnails.thumbnail(for: one, size: size)
        let second = await thumbnails.thumbnail(for: one, size: size)

        #expect(counter.calls == 1)
        #expect(first === second)
    }
}
