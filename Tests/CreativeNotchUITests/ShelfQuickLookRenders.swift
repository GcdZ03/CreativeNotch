import AppKit
import SwiftUI
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// The PNGs in `docs/assets/features/` for shelf Quick Look and Open,
/// rendered offscreen from the real `NotchRootView` on a stand-in wallpaper.
///
/// **Opt-in.** Every test here is skipped unless `CREATIVENOTCH_RENDER_DOCS`
/// is set, so the normal suite never rewrites a committed file:
///
///     CREATIVENOTCH_RENDER_DOCS=1 swift test --filter ShelfQuickLookRenders
///
/// Through an `NSHostingView` in an offscreen window rather than
/// `ImageRenderer`, which does not draw `ScrollView` content — and the
/// shelf's tiles live in one. Nothing is put on screen: the window is never
/// ordered in. Thumbnails are the file-type icons, as a tile shows before
/// its Quick Look thumbnail arrives; Quick Look's own panel and the context
/// menu are system windows and are not drawn here.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CREATIVENOTCH_RENDER_DOCS"] != nil))
struct ShelfQuickLookRenders {

    private static var output: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/assets/features", isDirectory: true)
    }

    /// A shelf folder holding a few real files, so each tile shows its
    /// type's icon. Written before the store is built: the store lists the
    /// folder, so they load as ready items.
    private static func shelf(copier: ShelfCopier = .system) throws -> ShelfStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shelf-render-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let names = ["Notes.txt", "Hero shot.png", "Brief.pdf"]
        for (offset, name) in names.enumerated() {
            let url = dir.appendingPathComponent(name)
            try Data("render".utf8).write(to: url)
            // Oldest first, so the shelf (newest first) reads Brief, Hero, Notes.
            try FileManager.default.setAttributes(
                [.creationDate: Date(timeIntervalSinceNow: Double(offset - 10) * 60)],
                ofItemAtPath: url.path
            )
        }
        return try ShelfStore(directory: dir, copier: copier, trash: TestTrash.shelf)
    }

    private static func state(_ shelf: ShelfStore) -> AppState {
        let s = PanelRenderingTests.state()
        s.shelf = shelf
        s.transition(to: .open(.shelf))
        return s
    }

    /// 2× the 620×260 panel over a wallpaper gradient, the size and framing
    /// of the README's renders.
    private static func write(_ s: AppState, to name: String) throws {
        let content = ZStack {
            LinearGradient(
                colors: [Color(red: 0.36, green: 0.30, blue: 0.62), Color(red: 0.86, green: 0.52, blue: 0.62)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            NotchRootView(app: s, now: Date(timeIntervalSinceReferenceDate: 0))
        }
        .frame(width: 620, height: 260)
        .environment(\.colorScheme, .dark)

        let host = NSHostingView(rootView: content)
        host.frame = CGRect(x: 0, y: 0, width: 620, height: 260)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1240, pixelsHigh: 520,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        rep.size = host.bounds.size
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))

        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try png.write(to: output.appendingPathComponent(name))
    }

    /// Tiles on the shelf with one selected: the ring, and the line under
    /// the shelf saying what Space and a double-click do.
    @Test func selected() throws {
        let shelf = try Self.shelf()
        let s = Self.state(shelf)
        s.shelfSelection = shelf.items.first { $0.displayName == "Hero shot.png" }?.id
        try Self.write(s, to: "shelf-quicklook-selected.png")
    }

    /// The same shelf with nothing selected: no ring, no hint — the shelf
    /// as it looked before, so the feature costs the idle pane nothing.
    @Test func idle() throws {
        let s = Self.state(try Self.shelf())
        try Self.write(s, to: "shelf-quicklook-idle.png")
    }

    /// A file still copying in beside a selected one: the copying tile is
    /// dimmed under its spinner and can be neither selected, previewed nor
    /// opened.
    @Test func pending() async throws {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let shelf = try Self.shelf(copier: ShelfCopier(
            copy: { _, _ in for await _ in stream {}; throw CancellationError() },
            availableCapacity: { _ in nil }
        ))
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("render-src-\(UUID().uuidString)")
            .appendingPathComponent("Holiday.mov")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("render".utf8).write(to: source)
        let copying = try shelf.add(.file(source), now: Date())
        let s = Self.state(shelf)
        // Asking for the copying tile selects nothing; the ring stays put.
        s.shelfSelection = shelf.items.first { $0.displayName == "Brief.pdf" }?.id
        #expect(ShelfPreview.request(for: copying.id, in: shelf.items) == nil)
        try Self.write(s, to: "shelf-quicklook-pending.png")
        continuation.finish()
        await shelf.waitForPendingCopies()
    }
}
