@preconcurrency import AVFoundation
import AppKit
import SwiftUI
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// Renders the review follow-ups' screenshots into
/// `docs/assets/features/followups-*.png`, with the renderer the rest of the
/// suite uses, on a stand-in wallpaper -- the way `panel-timer-render.png`
/// was made.
///
/// **Opt-in.** Skipped unless `CREATIVENOTCH_RENDER_SCREENSHOTS` is set, so
/// the normal suite never rewrites files in the repository:
///
///     CREATIVENOTCH_RENDER_SCREENSHOTS=1 swift test --filter FollowupScreenshotTests
///
/// Nothing here touches the real shelf folder, the Trash, defaults or the
/// camera: the shelf is a temporary store over the tests' stand-in Trash,
/// and the camera tab is drawn in its denied state over a session with no
/// inputs, which asks the system for nothing.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CREATIVENOTCH_RENDER_SCREENSHOTS"] != nil))
struct FollowupScreenshotTests {

    static let output = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("docs/assets/features")

    /// 14" MacBook Pro, as `TextSizeRenderingTests` uses.
    static let laptop = TextSizeRenderingTests.screen

    static func state(on screen: ScreenMetrics, textSize: TextSize = .standard) -> AppState {
        let s = AppState()
        s.textSize = textSize
        let anchor = NotchGeometry.anchor(for: screen)
        s.setGeometry(
            anchor: anchor,
            panelFrame: NotchGeometry.panelFrame(for: anchor, in: screen, textScale: textSize.scale)
        )
        s.hasBattery = true
        s.showsMediaControls = true
        s.power = PowerSnapshot(level: 67, source: .battery, isCharging: false, isLowPowerMode: false)
        return s
    }

    /// The panel over a stand-in wallpaper, at 2x, cropped to `crop` (in
    /// points, top-left origin) when given.
    static func write(_ s: AppState, _ name: String, crop: CGRect? = nil) throws {
        let size = s.panelFrame.size
        let view = ZStack(alignment: .top) {
            LinearGradient(
                colors: [Color(red: 0.55, green: 0.36, blue: 0.85), Color(red: 0.16, green: 0.45, blue: 0.95)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            NotchRootView(app: s, now: Date(timeIntervalSinceReferenceDate: 0))
        }
        .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        var image = try #require(renderer.cgImage)
        if let crop {
            let pixels = CGRect(x: crop.minX * 2, y: crop.minY * 2, width: crop.width * 2, height: crop.height * 2)
            image = try #require(image.cropping(to: pixels))
        }
        let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try png.write(to: output.appendingPathComponent("followups-\(name).png"))
    }

    /// Undo that could not bring every file back says so under the shelf.
    @Test func shelfRestoreNotice() throws {
        let s = Self.state(on: Self.laptop)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-shot-\(UUID())")
        s.shelf = try ShelfStore(directory: dir, trash: TestTrash.shelf)
        s.shelfNotice = ShelfRestoration(restored: [], skipped: [
            ShelfItem(id: UUID(), url: dir.appendingPathComponent("a"), displayName: "a", addedAt: Date()),
            ShelfItem(id: UUID(), url: dir.appendingPathComponent("b"), displayName: "b", addedAt: Date()),
        ]).notice
        s.transition(to: .open(.shelf))
        try Self.write(s, "shelf-restore-notice")
    }

    /// Larger text on a screen too small for the enlarged panel: fitted,
    /// not clipped.
    @Test func textSizeOnASmallScreen() throws {
        let small = ScreenMetrics(
            frame: CGRect(x: 0, y: 0, width: 720, height: 320),
            safeAreaTopInset: 0, auxiliaryTopLeftWidth: 0, auxiliaryTopRightWidth: 0, menuBarHeight: 24
        )
        let s = Self.state(on: small, textSize: .larger)
        s.countdown = Countdown(duration: 25 * 60, startingAt: Date(timeIntervalSinceReferenceDate: -7 * 60))
        s.transition(to: .open(.timer))
        try Self.write(s, "textsize-small-screen")
    }

    /// The camera tab at Larger text: the close, shutter and record glyphs
    /// scale with it now, beside the default for comparison.
    @Test func cameraControlsFollowTextSize() throws {
        for size in [TextSize.standard, .larger] {
            let s = Self.state(on: Self.laptop, textSize: size)
            s.cameraSession = AVCaptureSession()
            s.cameraQueue = DispatchQueue(label: "test.camera")
            s.cameraState = .denied
            s.transition(to: .open(.camera))
            try Self.write(s, size == .standard ? "camera-default" : "camera-larger")
        }
    }

    /// The closed notch with a paused timer: a pause glyph ahead of the
    /// dimmed digits, on a 14" and a 16" notch.
    @Test func pausedTimerBadge() throws {
        let sixteen = ScreenMetrics(
            frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
            safeAreaTopInset: 38, auxiliaryTopLeftWidth: 749, auxiliaryTopRightWidth: 749, menuBarHeight: 38
        )
        let start = Date(timeIntervalSinceReferenceDate: -60)
        for (name, screen, duration) in [("14in", Self.laptop, 25.0 * 60), ("16in", sixteen, 45.0)] {
            let s = Self.state(on: screen)
            s.countdown = Countdown(duration: duration, startingAt: start)?
                .paused(at: Date(timeIntervalSinceReferenceDate: -30))
            let anchor = s.anchor.rect
            let localMidX = anchor.midX - s.panelFrame.minX
            let crop = CGRect(x: localMidX - 170, y: 0, width: 340, height: anchor.height + 22)
            try Self.write(s, "timer-badge-paused-\(name)", crop: crop)
        }
    }
}
