import AppKit
import SwiftUI
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// That the notch *draws* the lyrics it is given (spec 2026-10-29): the
/// wiring can be right and a view can still drop the line.
///
/// Also holds the renders in `docs/assets/features/lyrics-*.png`, behind
/// `CREATIVENOTCH_RENDER_FEATURES`:
///
///     CREATIVENOTCH_RENDER_FEATURES=1 swift test --filter LyricsRenderingTests
@MainActor
struct LyricsRenderingTests {

    static let screen = TextSizeRenderingTests.screen
    private static let instant = Date(timeIntervalSinceReferenceDate: 0)

    static func state(
        lyrics: LyricsText?, playing: Bool = true, showing: NotchState = .closed, anchoredAt: Date = instant
    ) -> AppState {
        let s = AppState()
        let anchor = NotchGeometry.anchor(for: screen)
        s.setGeometry(anchor: anchor, panelFrame: NotchGeometry.panelFrame(for: anchor, in: screen, textScale: 1))
        s.nowPlaying = track(playing: playing, anchoredAt: anchoredAt)
        s.showsMediaControls = true
        s.lyrics = lyrics
        s.transition(to: showing)
        return s
    }

    /// `anchoredAt` is the render's pinned instant for the tests; the feature
    /// renders pass the real clock, because the peek's times are
    /// `Text(timerInterval:)` and read the wall clock whatever `now` says.
    static func track(playing: Bool = true, anchoredAt: Date = instant) -> TrackSnapshot {
        TrackSnapshot(
            title: "I Want to Live", artist: "Borislav Slavov", album: "Baldur's Gate 3", isPlaying: playing,
            position: PlaybackPosition(elapsed: 18, duration: 233, anchoredAt: anchoredAt)
        )
    }

    static func png(_ s: AppState) -> Data? {
        let size = s.panelFrame.size
        let renderer = ImageRenderer(
            content: NotchRootView(app: s, now: instant).frame(width: size.width, height: size.height)
        )
        renderer.scale = 1
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    static func bitmap(_ s: AppState) -> NSBitmapImageRep? {
        png(s).flatMap(NSBitmapImageRep.init(data:))
    }

    /// The strip, panel-local and top-left origin: below the band, under
    /// the housing.
    static func strip(_ s: AppState) -> CGRect {
        let housing = TextSizeRenderingTests.housing(s)
        return CGRect(x: housing.minX, y: housing.maxY, width: housing.width, height: NotchGeometry.lyricsLineHeight)
    }

    private static let line = LyricsText(current: "I feel your breath upon my neck")

    // MARK: - The strip

    @Test func theLineIsDrawnUnderTheNotch() throws {
        let b = try #require(Self.bitmap(Self.state(lyrics: Self.line)))
        #expect(PanelRenderingTests.ink(b, in: Self.strip(Self.state(lyrics: Self.line))) > 0.02, "no line under the notch")
        // Still nothing behind the camera housing.
        #expect(PanelRenderingTests.ink(b, in: TextSizeRenderingTests.housing(Self.state(lyrics: Self.line))) == 0)
    }

    @Test func aNewLineIsANewDrawing() throws {
        let a = try #require(Self.png(Self.state(lyrics: Self.line)))
        let b = try #require(Self.png(Self.state(lyrics: LyricsText(current: "A soft caress as cold as death"))))
        #expect(Render.differs(a, b))
    }

    /// A break keeps the strip, with a glyph, rather than collapsing it.
    @Test func aBreakDrawsTheNoteRatherThanNothing() throws {
        let s = Self.state(lyrics: LyricsText(current: ""))
        let b = try #require(Self.bitmap(s))
        #expect(PanelRenderingTests.ink(b, in: Self.strip(s)) > 0.002)
    }

    @Test func pausedThereIsNoStrip() throws {
        let s = Self.state(lyrics: Self.line, playing: false)
        let b = try #require(Self.bitmap(s))
        #expect(PanelRenderingTests.ink(b, in: Self.strip(s)) == 0)
    }

    // MARK: - The peek and the panel

    @Test func thePeekDrawsTheLine() throws {
        let track = Self.track()
        let with = try #require(Self.png(Self.state(lyrics: Self.line, showing: .peek(.nowPlaying(track)))))
        let other = try #require(Self.png(Self.state(
            lyrics: LyricsText(current: "Something else entirely"), showing: .peek(.nowPlaying(track))
        )))
        #expect(Render.differs(with, other))
    }

    @Test func thePanelDrawsTheLine() throws {
        let a = try #require(Self.png(Self.state(lyrics: Self.line, showing: .open(.shelf))))
        let b = try #require(Self.png(Self.state(
            lyrics: LyricsText(current: "Something else entirely"), showing: .open(.shelf)
        )))
        #expect(Render.differs(a, b))
        let none = try #require(Self.png(Self.state(lyrics: nil, showing: .open(.shelf))))
        #expect(Render.differs(a, none))
    }

    // MARK: - The feature renders (opt-in)

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CREATIVENOTCH_RENDER_FEATURES"] != nil))
    func renderFeatureImages() throws {
        let out = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/assets/features", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let now = Date()
        let track = Self.track(anchoredAt: now)
        try write(DownloadsRenderingTests.desk(Self.state(lyrics: Self.line, anchoredAt: now), height: 72),
                  to: out.appendingPathComponent("lyrics-strip.png"))
        try write(DownloadsRenderingTests.desk(Self.state(lyrics: Self.line, showing: .peek(.nowPlaying(track)), anchoredAt: now), height: 168),
                  to: out.appendingPathComponent("lyrics-peek.png"))
        try write(DownloadsRenderingTests.desk(Self.state(lyrics: Self.line, showing: .open(.shelf), anchoredAt: now), height: 260),
                  to: out.appendingPathComponent("lyrics-panel.png"))
    }

    private func write(_ data: Data?, to url: URL) throws {
        let data = try #require(data, "nothing rendered for \(url.lastPathComponent)")
        try data.write(to: url)
    }
}
