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

    static func png(_ color: NSColor) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 40, pixelsHigh: 40,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill()
        NSRect(x: 0, y: 0, width: 40, height: 40).fill()
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
    /// panel-local (195, 222, 264, 38) mirrored in y against a 260pt panel
    /// puts it flush with the panel's top edge.
    ///
    /// Literals, not `NotchRootView.drawnRect(for:)`: a test that asks the
    /// production code where it drew and then checks it drew there proves
    /// only that it agrees with itself.
    private static let drawn = CGRect(x: 195, y: 0, width: 264, height: 38)

    /// The strip the shape grew for the badge — the 34pt trailing the
    /// notch's own 230pt. Nothing else in the closed notch may be painted.
    private static let badgeStrip = CGRect(x: 425, y: 0, width: 34, height: 38)

    private static let playing = TrackSnapshot(title: "Song", artist: "Band", isPlaying: true)
    private static let paused  = TrackSnapshot(title: "Song", artist: "Band", isPlaying: false)

    // MARK: - Rendering

    private static func closedNotch(
        countdown: Countdown? = nil, nowPlaying: TrackSnapshot?, artwork: Data?
    ) -> NSBitmapImageRep? {
        let state = AppState()
        state.setGeometry(anchor: .notch(Self.anchor), panelFrame: Self.panel)
        state.countdown = countdown
        state.nowPlaying = nowPlaying
        state.nowPlayingArtwork = artwork

        let renderer = ImageRenderer(
            content: NotchRootView(app: state)
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
    /// Started from the wall clock rather than a fixed instant because
    /// `NotchRootView` reads `Date()` itself; 25 minutes is longer than
    /// any render here takes.
    private static func running() -> Countdown {
        Countdown(duration: 1500, startingAt: Date())!
    }

    /// The bounding box of every pixel carrying `marker`'s hue, in the
    /// image's own top-left coordinates. `nil` when the colour is absent.
    ///
    /// Deliberately generous about the exact channel values: the cover is
    /// resampled, clipped to a rounded rect and stroked, so its edge pixels
    /// are blends. Only the interior has to be recognisably the marker.
    private static func paintedBox(_ bitmap: NSBitmapImageRep, _ marker: NSColor) -> CGRect? {
        let want = marker.usingColorSpace(.deviceRGB)!
        var box: CGRect?
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
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

        #expect(once == twice)
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

        #expect(withCover != noCover)
    }

    /// And it is *this* track's cover, not a fixed piece of now-playing
    /// chrome that happens to appear whenever artwork exists.
    @Test func theBadgeDrawsThisTracksCoverAndNotAFixedTile() throws {
        let red  = try #require(Self.pixels(nowPlaying: Self.playing, artwork: SolidArtwork.red))
        let blue = try #require(Self.pixels(nowPlaying: Self.playing, artwork: SolidArtwork.blue))

        #expect(red != blue)
    }

    // MARK: - It is drawn where the shape grew for it

    /// The one that matters most, and the one no comparison of two images
    /// can make: a closed notch's own rect *is* the camera housing, so a
    /// cover drawn anywhere but the 34pt strip trailing it is invisible on
    /// real hardware while every pixel-difference test still passes.
    ///
    /// Flip the overlay's `alignment` to `.leading` and the cover lands at
    /// x 201 — dead centre of the housing — and this fails. Delete the
    /// overlay and there is no cover to find at all.
    @Test func theBadgeIsDrawnInTheStripTheShapeGrewForIt() throws {
        let image = try #require(Self.closedNotch(nowPlaying: Self.playing, artwork: SolidArtwork.red))
        let cover = try #require(Self.paintedBox(image, .systemRed))

        #expect(Self.badgeStrip.contains(cover))
        // The exact tile, not merely "somewhere inside": this is the
        // drawn consequence of `nowPlayingBadgeWidth == 34` holding
        // `NowPlayingBadgeView`'s 22pt cover with 6pt gutters, which is
        // the constant's stated rationale and was otherwise unenforced.
        // Widen the constant to 50 and the cover slides to x 447.
        #expect(cover == CGRect(x: 431, y: 8, width: 22, height: 22))
        #expect(cover.minX - Self.badgeStrip.minX == 6)
        #expect(Self.badgeStrip.maxX - cover.maxX == 6)
        // And the strip really is outside the notch it trails.
        #expect(Self.badgeStrip.minX == Self.drawn.minX + Self.anchor.width)
        #expect(Self.badgeStrip.maxX == Self.drawn.maxX)
    }

    /// The mirror image: paused media is not playing media, so nothing may
    /// be painted into the closed notch even though the cache still holds a
    /// cover for the track.
    @Test func nothingIsDrawnInTheClosedNotchWhileMediaIsPaused() throws {
        let image = try #require(Self.closedNotch(nowPlaying: Self.paused, artwork: SolidArtwork.red))

        #expect(Self.paintedBox(image, .systemRed) == nil)
    }

    // MARK: - The slot is shared, and the timer owns it

    /// The slot holds one badge, and while a timer runs that badge is the
    /// timer's — so the album cover must not be painted, even though media
    /// is playing and its artwork is cached.
    ///
    /// The only test that bites the mistake the identity exists to
    /// prevent. `NotchRootView` branches on `slot == .nowPlaying`; widen
    /// that to `slot != BadgeSlot.none` — which is what a width-based
    /// `> 0` amounts to — and the cover lands in the countdown's 44pt slot
    /// with every other test in the suite still green, because nothing
    /// else renders a closed notch with a countdown set.
    @Test func aRunningTimerKeepsTheAlbumCoverOutOfTheSlot() throws {
        let image = try #require(Self.closedNotch(
            countdown: Self.running(), nowPlaying: Self.playing, artwork: SolidArtwork.red
        ))

        #expect(Self.paintedBox(image, .systemRed) == nil)
    }

    /// The vacuity guard for the test above: the countdown really does
    /// reach the view. Without this, a `countdown` that never arrived
    /// would make "no cover was painted" pass for the wrong reason.
    ///
    /// The difference is the shape — 230 + 44 rather than 230 + 34 — and
    /// the cover's absence. It says the countdown changed the render; it
    /// does not say what changed, which is what the assertion above is for.
    @Test func aRunningTimerChangesTheClosedNotch() throws {
        let timed = try #require(Self.pixels(
            countdown: Self.running(), nowPlaying: Self.playing, artwork: SolidArtwork.red
        ))
        let media = try #require(Self.pixels(nowPlaying: Self.playing, artwork: SolidArtwork.red))

        #expect(timed != media)
    }
}
