import AppKit
import SwiftUI
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// Album art a test can find again once it has been drawn.
///
/// A saturated flat colour, so `paintedBox` can say *where* the cover
/// landed rather than merely that two images differ. Drawn into a bitmap
/// rep rather than through `NSImage.lockFocus`, so nothing here needs a
/// window server. Shared with `PeekRenderingTests`, which asks the same
/// question of the peek's own cover.
enum SolidArtwork {
    static let red  = png(.systemRed)
    static let blue = png(.systemBlue)

    /// A 16:9 frame, like a video thumbnail.
    static let wideRed = png(.systemRed, width: 64, height: 36)

    static func png(_ color: NSColor, width: Int = 40, height: Int = 40) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }
}

/// What the badge actually *draws*.
///
/// `NowPlayingBadgeShapeTests` and `NowPlayingBadgeTests` prove the closed
/// notch grows 34pt on its trailing side and that all three consumers of
/// that rectangle agree about it. Neither looks inside the rectangle. The
/// review of `e903635` deleted the overlay outright, flipped it to
/// `.leading` — which renders the cover behind the camera housing — and
/// hard-coded `artwork: nil`; all 514 tests passed every time. A perfect
/// rectangle with nothing in it is precisely how `.peek(.nowPlaying)`
/// shipped drawing the literal string "CreativeNotch" on this same branch.
///
/// Read `PeekRenderingTests`' header before adding here. Its
/// `peekViewPixels` helper documents the trap: going through
/// `NotchRootView` changes the panel *shape* as well as its content, so two
/// images taken either side of a playback change differ whatever is drawn
/// inside them, and such a test cannot fail. Every test below therefore
/// either holds the shape fixed and varies exactly one thing inside it, or
/// takes a single render and asks where the paint landed.
@MainActor
struct BadgeRenderingTests {

    // The same synthetic notched screen `NowPlayingBadgeTests` uses:
    // anchor (2090, 1118, 230, 38) inside panel (1895, 896, 620, 260).
    private static let anchor = CGRect(x: 2090, y: 1118, width: 230, height: 38)
    private static let panel  = CGRect(x: 1895, y: 896, width: 620, height: 260)

    /// The badged closed rect in the top-left space SwiftUI lays out in:
    /// panel-local (195, 222, 298, 38) mirrored in y against a 260pt panel
    /// puts it flush with the panel's top edge. 230 + 68: the cover and the
    /// equalizer together in the trailing ear (2026-10-17).
    ///
    /// Literals, not `NotchRootView.drawnRect(for:)`: a test that asks the
    /// production code where it drew and then checks it drew there proves
    /// only that it agrees with itself.
    private static let drawn = CGRect(x: 195, y: 0, width: 298, height: 38)

    /// The 68pt ear the shape grew past the notch's trailing edge (x 425).
    private static let ear = CGRect(x: 425, y: 0, width: 68, height: 38)

    /// Where the bars start for a square cover: 6pt, the 22pt tile, 5pt.
    private static let barsStartSquare: CGFloat = 425 + 6 + 22 + 5

    private static let playing = TrackSnapshot(title: "Song", artist: "Band", isPlaying: true)
    private static let paused  = TrackSnapshot(title: "Song", artist: "Band", isPlaying: false)

    // MARK: - Rendering

    /// `now` pins the instant the view decides the badge slot at. `nil` —
    /// the default and what the app itself passes — leaves the view reading
    /// the wall clock once per `body` evaluation.
    private static func closedNotch(
        countdown: Countdown? = nil,
        now: Date? = nil,
        nowPlaying: TrackSnapshot?,
        artwork: Data?
    ) -> NSBitmapImageRep? {
        let state = AppState()
        state.setGeometry(anchor: .notch(Self.anchor), panelFrame: Self.panel)
        state.countdown = countdown
        state.nowPlaying = nowPlaying
        state.nowPlayingArtwork = artwork

        let renderer = ImageRenderer(
            content: NotchRootView(app: state, now: now)
                .frame(width: Self.panel.width, height: Self.panel.height)
        )
        renderer.scale = 1
        guard
            let image = renderer.nsImage,
            let tiff = image.tiffRepresentation
        else { return nil }
        return NSBitmapImageRep(data: tiff)
    }

    private static func pixels(
        countdown: Countdown? = nil, nowPlaying: TrackSnapshot?, artwork: Data?
    ) -> Data? {
        closedNotch(countdown: countdown, nowPlaying: nowPlaying, artwork: artwork)?
            .representation(using: .png, properties: [:])
    }

    /// A countdown that is still running whenever it is read.
    ///
    /// Started from the wall clock rather than a fixed instant because the
    /// tests that use it leave `now` unpinned, so the view reads `Date()`
    /// itself; 25 minutes is longer than any render here takes.
    private static func running() -> Countdown {
        Countdown(duration: 1500, startingAt: Date())!
    }

    /// The bounding box of every pixel carrying `marker`'s hue, in the
    /// image's own top-left coordinates. `nil` when the colour is absent.
    ///
    /// Deliberately generous about the exact channel values: the cover is
    /// resampled, clipped to a rounded rect and stroked, so its edge pixels
    /// are blends. Only the interior has to be recognisably the marker.
    ///
    /// `region` limits the search, for a marker that legitimately appears
    /// twice: the equalizer takes its tint from the same red cover.
    private static func paintedBox(
        _ bitmap: NSBitmapImageRep, _ marker: NSColor, in region: CGRect? = nil
    ) -> CGRect? {
        let want = marker.usingColorSpace(.deviceRGB)!
        let area = region ?? CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
        var box: CGRect?
        for y in Int(area.minY)..<Int(area.maxY) {
            for x in Int(area.minX)..<Int(area.maxX) {
                guard let raw = bitmap.colorAt(x: x, y: y),
                      let c = raw.usingColorSpace(.deviceRGB),
                      c.alphaComponent > 0.5,
                      abs(c.redComponent   - want.redComponent)   < 0.2,
                      abs(c.greenComponent - want.greenComponent) < 0.2,
                      abs(c.blueComponent  - want.blueComponent)  < 0.2
                else { continue }
                let point = CGRect(x: CGFloat(x), y: CGFloat(y), width: 1, height: 1)
                box = box.map { $0.union(point) } ?? point
            }
        }
        return box
    }

    // MARK: - The control

    /// Without this every `!=` below would be worthless: a renderer that
    /// produced noise would make any two images differ no matter what the
    /// view did.
    @Test func renderingTheSameClosedNotchTwiceIsIdentical() throws {
        let once  = try #require(Self.pixels(nowPlaying: Self.playing, artwork: SolidArtwork.red))
        let twice = try #require(Self.pixels(nowPlaying: Self.playing, artwork: SolidArtwork.red))

        #expect(Render.same(once, twice))
    }

    // MARK: - Something is drawn, and it is the artwork

    /// Music plays in both renders, so the drawn *shape* is the badged one
    /// in both and the only variable is what the badge holds.
    ///
    /// Delete the overlay from `NotchRootView`'s `.closed` case, or pin it
    /// to `artwork: nil`, and these two rasterise identically.
    @Test func theBadgeDrawsTheArtworkItRepresents() throws {
        let withCover = try #require(Self.pixels(nowPlaying: Self.playing, artwork: SolidArtwork.red))
        let noCover   = try #require(Self.pixels(nowPlaying: Self.playing, artwork: nil))

        #expect(Render.differs(withCover, noCover))
    }

    /// And it is *this* track's cover, not a fixed piece of now-playing
    /// chrome that happens to appear whenever artwork exists.
    @Test func theBadgeDrawsThisTracksCoverAndNotAFixedTile() throws {
        let red  = try #require(Self.pixels(nowPlaying: Self.playing, artwork: SolidArtwork.red))
        let blue = try #require(Self.pixels(nowPlaying: Self.playing, artwork: SolidArtwork.blue))

        #expect(Render.differs(red, blue))
    }

    // MARK: - It is drawn where the shape grew for it

    /// The one that matters most, and the one no comparison of two images
    /// can make: a closed notch's own rect *is* the camera housing, so a
    /// cover drawn anywhere but the ear past it is invisible on real
    /// hardware while every pixel-difference test still passes.
    ///
    /// Centre the cover and it lands in the housing, and this fails.
    /// Delete the overlay and there is no cover to find at all.
    @Test func theCoverIsDrawnJustPastTheNotchInTheRightEar() throws {
        let image = try #require(Self.closedNotch(nowPlaying: Self.playing, artwork: SolidArtwork.red))
        // Everything left of where the bars start — the housing and the
        // left of the menu bar included — so a cover that drifted is found.
        let leftOfBars = CGRect(x: 0, y: 0, width: Self.barsStartSquare - 1, height: Self.drawn.height)
        let cover = try #require(Self.paintedBox(image, .systemRed, in: leftOfBars))

        // The exact tile: 6pt past the notch's edge, 22pt square, centred
        // in the band.
        #expect(cover == CGRect(x: 431, y: 8, width: 22, height: 22))
        #expect(Self.ear.contains(cover))
    }

    /// The equalizer follows the cover in the same ear, tinted from it, and
    /// the whole badge stays inside the ear.
    @Test func theEqualizerFollowsTheCoverInTheEar() throws {
        let image = try #require(Self.closedNotch(nowPlaying: Self.playing, artwork: SolidArtwork.red))
        let afterCover = CGRect(
            x: Self.barsStartSquare - 1, y: 0,
            width: CGFloat(image.pixelsWide) - Self.barsStartSquare + 1, height: Self.drawn.height
        )
        let bars = try #require(Self.paintedBox(image, .systemRed, in: afterCover))

        #expect(Self.ear.contains(bars))
        #expect(bars.minX >= Self.barsStartSquare - 1)
    }

    /// A 16:9 video thumbnail gets the wider tile, capped at 1.5×, so more
    /// of the picture shows than a square crop would allow.
    @Test func wideArtworkGetsAWiderTile() throws {
        let image = try #require(Self.closedNotch(nowPlaying: Self.playing, artwork: SolidArtwork.wideRed))
        let cover = try #require(Self.paintedBox(
            image, .systemRed, in: CGRect(x: 0, y: 0, width: 425 + 6 + 33 + 2, height: Self.drawn.height)
        ))
        #expect(cover == CGRect(x: 431, y: 8, width: 33, height: 22))
    }

    /// The mirror image: paused media is not playing media, so nothing may
    /// be painted into the closed notch even though the cache still holds a
    /// cover for the track.
    @Test func nothingIsDrawnInTheClosedNotchWhileMediaIsPaused() throws {
        let image = try #require(Self.closedNotch(nowPlaying: Self.paused, artwork: SolidArtwork.red))

        #expect(Self.paintedBox(image, .systemRed) == nil)
    }

    // MARK: - Music and the timer side by side (2026-10-29)

    /// With a timer running the music keeps its segment, nearest the notch,
    /// and the cover is painted there -- inside its own segment and nowhere
    /// in the timer's, which starts where the music's ends.
    ///
    /// The test that bites a segment drawing another's content: the cover
    /// in the countdown's 44pt, or the timer's digits pushing the cover out.
    @Test func aRunningTimerKeepsTheAlbumCoverInItsOwnSegment() throws {
        let image = try #require(Self.closedNotch(
            countdown: Self.running(), nowPlaying: Self.playing, artwork: SolidArtwork.red
        ))
        let segments = NotchShape.badgeSegments([.nowPlaying, .timer], anchor: .notch(Self.anchor), panelFrame: Self.panel)
        let cover = try #require(Self.paintedBox(image, .systemRed), "the cover is painted")
        #expect(cover.minX >= segments[0].rect.minX)
        #expect(cover.maxX <= segments[0].rect.maxX, "the cover stays out of the timer's segment")
    }

    /// The vacuity guard for the test above: the countdown really does
    /// reach the view. Without this, a `countdown` that never arrived
    /// would make "no cover was painted" pass for the wrong reason.
    ///
    /// The difference is the shape — 230 + 44 rather than 34 + 230 + 34 — and
    /// the cover's absence. It says the countdown changed the render; it
    /// does not say what changed, which is what the assertion above is for.
    @Test func aRunningTimerChangesTheClosedNotch() throws {
        let timed = try #require(Self.pixels(
            countdown: Self.running(), nowPlaying: Self.playing, artwork: SolidArtwork.red
        ))
        let media = try #require(Self.pixels(nowPlaying: Self.playing, artwork: SolidArtwork.red))

        #expect(Render.differs(timed, media))
    }

    // MARK: - One clock read decides the whole frame

    /// A fixed instant in 2001, far enough from any wall clock that a
    /// countdown running *at* it has finished many times over by `Date()`.
    /// That gap is the whole mechanism below.
    private static let pinned = Date(timeIntervalSince1970: 1_000_000_000)

    /// The reserved width and the drawn content come from **one** reading
    /// of the clock.
    ///
    /// This is the invariant `body` was restructured for, and it was held
    /// in place by a doc comment alone: reverting the width side to a
    /// second, independent `Date()` read left all 575 tests green, because
    /// the divergence only shows when two reads microseconds apart straddle
    /// the instant a timer finishes — not reasonably reachable by waiting.
    ///
    /// Pinning `now` makes it reachable. The countdown below has one second
    /// left at `pinned` and finished twenty years ago by the wall clock, so
    /// any read `body` takes that is *not* the pinned instant answers
    /// `.none` and the shape collapses to the bare 230pt notch. The two
    /// widths differ by exactly `timerBadgeWidth`, so a second read is a
    /// 44pt error rather than a race.
    ///
    /// Measured off the black shape itself rather than off
    /// `NotchRootView.drawnRect`, which is the *other* derivation and would
    /// only prove the view agrees with itself. Nothing else is painted into
    /// a closed notch with no media, so the black bounding box is the
    /// drawn rect.
    @Test func theReservedWidthAndTheDrawnContentComeFromOneClockRead() throws {
        // One second from finishing at `pinned`, and finished exactly at it.
        let running  = try #require(
            Countdown(duration: 1500, startingAt: Self.pinned.addingTimeInterval(-1499))
        )
        let finished = try #require(
            Countdown(duration: 1500, startingAt: Self.pinned.addingTimeInterval(-1500))
        )

        let withTimer = try #require(Self.closedNotch(
            countdown: running, now: Self.pinned, nowPlaying: nil, artwork: nil
        ))
        let without = try #require(Self.closedNotch(
            countdown: finished, now: Self.pinned, nowPlaying: nil, artwork: nil
        ))

        let timedBox = try #require(Self.paintedBox(withTimer, .black))
        let bareBox  = try #require(Self.paintedBox(without, .black))

        // 230 + 44 against 230 flat, both starting at the notch's own
        // leading edge. Literals for the same reason `drawn` above is one.
        #expect(timedBox == CGRect(x: 195, y: 0, width: 274, height: 38))
        #expect(bareBox  == CGRect(x: 195, y: 0, width: 230, height: 38))
        #expect(timedBox.width - bareBox.width == NotchGeometry.timerBadgeWidth)
    }
}
