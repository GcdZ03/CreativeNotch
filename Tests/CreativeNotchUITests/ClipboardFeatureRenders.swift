import AppKit
import SwiftUI
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// The pictures of clipboard search and pinning in
/// `docs/assets/features/`, rendered by the suite rather than screenshotted.
///
/// Opt-in: the suite would otherwise rewrite committed PNGs on every run.
/// Re-render with
///
///     CREATIVENOTCH_RENDER_FEATURES=1 swift test --filter ClipboardFeatureRenders
///
/// Rendered through an offscreen `NSHostingView` rather than
/// `ImageRenderer`, which runs neither `ScrollView` content nor the
/// AppKit-backed `TextField` — the two things these pictures are of. The
/// panel sits on a stand-in wallpaper, as the README's renders do: the
/// layout is exact, the desktop is not.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CREATIVENOTCH_RENDER_FEATURES"] == "1"))
struct ClipboardFeatureRenders {

    /// 1 January 2001, 10:00 in the render's own clock, so the row times
    /// read the same on every machine.
    private static let now = Date(timeIntervalSinceReferenceDate: 36_000)

    private static let outputDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Tests/CreativeNotchUITests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo root
        .appendingPathComponent("docs/assets/features")

    /// A history worth searching: a pinned address and snippet, then the
    /// day's ordinary copies, newest first.
    private static func store() -> ClipboardStore {
        let store = ClipboardStore()
        let copies: [(String, TimeInterval)] = [
            ("221B Baker Street, London NW1 6XE", -7_200),
            ("git rebase -i origin/main", -5_400),
            ("Invoice #2041 — March, paid in full", -3_000),
            ("https://developer.apple.com/documentation/appkit", -1_800),
            ("Meet at the Café Lumière at 6", -900),
            ("let total = items.reduce(0, +)", -420),
            ("Invoice #2042 — April, due on the 30th", -120),
        ]
        for (text, offset) in copies {
            store.record(.text(text), now: now.addingTimeInterval(offset))
        }
        for pinned in ["git rebase -i origin/main", "221B Baker Street, London NW1 6XE"] {
            if let entry = store.entries.first(where: { $0.content == .text(pinned) }) {
                store.pin(entry.id)
            }
        }
        return store
    }

    private static func state(store: ClipboardStore, query: String = "") -> AppState {
        let s = PanelRenderingTests.state()
        s.clipboard = store
        s.transition(to: .open(.clipboard))
        s.clipboardQuery = query
        return s
    }

    /// The panel on a stand-in wallpaper, at 2×, as a PNG.
    private static func render(_ s: AppState) throws -> Data {
        let size = CGSize(width: 660, height: 290)
        let root = ZStack(alignment: .top) {
            LinearGradient(
                colors: [Color(red: 0.36, green: 0.42, blue: 0.78), Color(red: 0.74, green: 0.45, blue: 0.70)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            NotchRootView(app: s, now: now)
                .frame(width: 620, height: 260)
        }
        .frame(width: size.width, height: size.height)
        .environment(\.animatesEqualizer, false)

        let host = NSHostingView(rootView: root)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // Two passes: the hosting view sizes its scroll content on the
        // first and draws it on the second.
        host.layoutSubtreeIfNeeded()

        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    private static func write(_ data: Data, _ name: String) throws {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try data.write(to: outputDirectory.appendingPathComponent("clipboard-search-pin-\(name).png"))
    }

    @Test func pinned() throws {
        try Self.write(try Self.render(Self.state(store: Self.store())), "pinned")
    }

    @Test func searching() throws {
        try Self.write(try Self.render(Self.state(store: Self.store(), query: "invoice")), "searching")
    }

    /// "cafe" finds "Café": case and accents are both ignored.
    @Test func diacritics() throws {
        try Self.write(try Self.render(Self.state(store: Self.store(), query: "cafe")), "diacritics")
    }

    @Test func noMatches() throws {
        try Self.write(try Self.render(Self.state(store: Self.store(), query: "receipt")), "no-matches")
    }
}
