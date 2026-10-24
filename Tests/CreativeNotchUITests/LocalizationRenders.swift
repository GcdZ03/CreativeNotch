import AppKit
import SwiftUI
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// The pictures in the localization PR and `docs/assets/features/i18n-*.png`:
/// the open panel in the states with the most words, every one of them now
/// read from `Localizable.xcstrings` — in English identical to before, which
/// is the point being shown.
///
/// Opt-in, so the ordinary suite never rewrites files in the repo:
///
///     CN_RENDER_FEATURES=1 swift test --filter LocalizationRenders
///
/// Rendered offscreen by the same `ImageRenderer` path the pixel tests use,
/// on a stand-in wallpaper like the README's panel picture.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CN_RENDER_FEATURES"] == "1"))
struct LocalizationRenders {

    static let states: [(name: String, apply: (AppState) -> Void)] = [
        ("welcome", {
            $0.welcomeSeen = false
            $0.transition(to: .open(.shelf), openedBy: .tap)
        }),
        ("timer", {
            $0.countdown = Countdown(duration: 25 * 60, startingAt: Date(timeIntervalSinceReferenceDate: -90))
            $0.transition(to: .open(.timer))
        }),
        ("shelf-empty", { $0.transition(to: .open(.shelf)) }),
        ("battery", { $0.transition(to: .open(.power)) }),
    ]

    @Test func renderTheFeaturePictures() throws {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docs/assets/features", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let shelfDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalizationRenders-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: shelfDirectory) }

        for state in Self.states {
            let s = PanelRenderingTests.state()
            s.shelf = try ShelfStore(directory: shelfDirectory, trash: TestTrash.shelf)
            state.apply(s)
            let png = try #require(Self.png(s))
            try png.write(to: directory.appendingPathComponent("i18n-\(state.name).png"))
        }
    }

    static func png(_ s: AppState) -> Data? {
        let size = s.panelFrame.size
        let renderer = ImageRenderer(
            content: ZStack(alignment: .top) {
                LinearGradient(
                    colors: [Color(red: 0.29, green: 0.33, blue: 0.62), Color(red: 0.62, green: 0.42, blue: 0.70)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                NotchRootView(app: s, now: Date(timeIntervalSinceReferenceDate: 0))
            }
            .frame(width: size.width, height: size.height)
        )
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
