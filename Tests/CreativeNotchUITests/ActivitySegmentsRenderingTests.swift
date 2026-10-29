import AppKit
import SwiftUI
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// That several activities are *drawn* side by side (2026-10-29), each in
/// its own segment, and the renders in `docs/assets/features/activities-*`,
/// behind `CREATIVENOTCH_RENDER_FEATURES`:
///
///     CREATIVENOTCH_RENDER_FEATURES=1 swift test --filter ActivitySegmentsRenderingTests
@MainActor
struct ActivitySegmentsRenderingTests {

    static let screen = TextSizeRenderingTests.screen
    private static let instant = Date(timeIntervalSinceReferenceDate: 0)

    static func state(
        countdown: Bool = false, stopwatch: Bool = false, downloads: Bool = false, capture: Bool = false,
        showing: NotchState = .closed
    ) -> AppState {
        let s = AppState()
        let anchor = NotchGeometry.anchor(for: screen)
        s.setGeometry(anchor: anchor, panelFrame: NotchGeometry.panelFrame(for: anchor, in: screen, textScale: 1))
        s.nowPlaying = TrackSnapshot(title: "Song", artist: "Band", isPlaying: true)
        s.nowPlayingArtwork = SolidArtwork.red
        if countdown {
            s.countdown = Countdown(duration: 25 * 60, startingAt: instant.addingTimeInterval(-8))
            s.timers = [RunningTimer(id: 0, countdown: s.countdown!)]
        }
        if stopwatch { s.stopwatch = Stopwatch().started(at: instant.addingTimeInterval(-72)).paused(at: instant) }
        if downloads { s.downloads = DownloadSummary(count: 1, percent: 42, leadingName: "Quarterly report.pdf") }
        if capture { s.captureUse = CaptureUse(microphone: true) }
        s.transition(to: showing)
        return s
    }

    static func bitmap(_ s: AppState) -> NSBitmapImageRep? {
        let size = s.panelFrame.size
        let renderer = ImageRenderer(
            content: NotchRootView(app: s, now: instant)
                .frame(width: size.width, height: size.height)
                .environment(\.animatesEqualizer, false)
                .environment(\.stopwatchCountsLive, false)
        )
        renderer.scale = 1
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)
    }

    /// Each segment, top-left origin, as the bitmap has it.
    static func segments(_ s: AppState) -> [BadgeSegment] {
        let slots = NotchRootView.badgeSlots(for: s, at: instant)
        return NotchShape.badgeSegments(slots, anchor: s.anchor, panelFrame: s.panelFrame).map {
            BadgeSegment(slot: $0.slot, rect: CGRect(
                x: $0.rect.minX, y: s.panelFrame.height - $0.rect.maxY, width: $0.rect.width, height: $0.rect.height
            ))
        }
    }

    /// All five on a 14" Mac: 248pt of segments for 215pt of room, so the
    /// stopwatch gives way and the rest -- the privacy dot included -- are
    /// drawn, each in its own segment, inside the window.
    @Test func everySegmentThatFitsIsDrawn() throws {
        let s = Self.state(countdown: true, stopwatch: true, downloads: true, capture: true)
        let b = try #require(Self.bitmap(s))
        let segments = Self.segments(s)
        #expect(segments.map(\.slot) == [.nowPlaying, .timer, .downloads, .capture])
        #expect(segments.last!.rect.maxX <= s.panelFrame.width, "inside the window")
        for segment in segments {
            #expect(PanelRenderingTests.ink(b, in: segment.rect.insetBy(dx: 2, dy: 2)) > 0.02, "\(segment.slot) is empty")
        }
        // And still nothing behind the camera housing.
        #expect(PanelRenderingTests.ink(b, in: TextSizeRenderingTests.housing(s)) == 0)
    }

    @Test func theTimerPeekIsDrawn() throws {
        let b = try #require(Self.bitmap(Self.state(countdown: true, showing: .peek(.timer))))
        let s = Self.state(countdown: true, showing: .peek(.timer))
        let rect = NotchRootView.drawnRect(for: s, now: Self.instant)
        let row = CGRect(x: rect.minX + 10, y: rect.maxY - NotchGeometry.statusPeekBodyHeight, width: rect.width - 20,
                         height: NotchGeometry.statusPeekBodyHeight)
        #expect(PanelRenderingTests.ink(b, in: row) > 0.02)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CREATIVENOTCH_RENDER_FEATURES"] != nil))
    func renderFeatureImages() throws {
        let out = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/assets/features", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let pairs: [(String, AppState, CGFloat)] = [
            ("activities-music-timer.png", Self.state(countdown: true), 64),
            ("activities-everything.png", Self.state(countdown: true, stopwatch: true, downloads: true, capture: true), 64),
            ("activities-timer-peek.png", Self.state(countdown: true, showing: .peek(.timer)), 92),
        ]
        for (name, s, height) in pairs {
            let data = try #require(DownloadsRenderingTests.desk(s, height: height), "nothing rendered for \(name)")
            try data.write(to: out.appendingPathComponent(name))
        }
    }
}
