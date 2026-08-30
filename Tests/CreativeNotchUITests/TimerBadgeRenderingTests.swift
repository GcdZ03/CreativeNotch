import AppKit
import SwiftUI
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// What `TimerBadgeView` actually *draws*.
///
/// Read the header on `BadgeRenderingTests` before adding here: going
/// through `NotchRootView` changes the drawn panel *shape* as well as its
/// content whenever a timer appears or disappears, so "render with a timer,
/// render without, assert the images differ" passes even if the badge
/// draws nothing at all. Every test below either renders `TimerBadgeView`
/// directly, at a fixed width, or — for the one test that does go through
/// `NotchRootView` — holds the slot's *identity* fixed and reads it as data
/// rather than rendering pixels.
@MainActor
struct TimerBadgeRenderingTests {

    private static func pixels(_ view: some View, width: CGFloat = 60) -> Data? {
        let renderer = ImageRenderer(content: view.frame(width: width, height: 32))
        renderer.scale = 1
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    // MARK: - The control

    @Test func renderingTheSameBadgeTwiceIsIdentical() throws {
        let a = try #require(Self.pixels(TimerBadgeView(text: "25m", isPaused: false)))
        let b = try #require(Self.pixels(TimerBadgeView(text: "25m", isPaused: false)))
        #expect(a == b)
    }

    // MARK: - Something is drawn, and it is the text

    /// Renders the badge directly, NOT through `NotchRootView`. Going
    /// through the root view changes the drawn panel *shape* as well as the
    /// content, so two images differ whether or not the badge painted
    /// anything — the trap `BadgeRenderingTests` and `PeekRenderingTests`
    /// document.
    @Test func theBadgeDrawsItsText() throws {
        let a = try #require(Self.pixels(TimerBadgeView(text: "25m", isPaused: false)))
        let b = try #require(Self.pixels(TimerBadgeView(text: "24m", isPaused: false)))
        #expect(a != b)
    }

    /// Pausing has to be visible, or a paused timer is indistinguishable
    /// from a stalled one.
    @Test func aPausedBadgeLooksDifferentFromARunningOne() throws {
        let running = try #require(Self.pixels(TimerBadgeView(text: "25m", isPaused: false)))
        let paused  = try #require(Self.pixels(TimerBadgeView(text: "25m", isPaused: true)))
        #expect(running != paused)
    }

    /// The widest string must fit the fixed width without truncating.
    /// Truncation would be the tell that `timerBadgeWidth` is too small.
    @Test func theWidestStringFitsTheFixedWidth() throws {
        // Both renders must succeed at all — a crash or a nil render at the
        // narrow width would be the tell of a layout that cannot fit.
        _ = try #require(Self.pixels(
            TimerBadgeView(text: TimerDisplay.widestText, isPaused: false),
            width: NotchGeometry.timerBadgeWidth
        ))
        _ = try #require(Self.pixels(
            TimerBadgeView(text: TimerDisplay.widestText, isPaused: false),
            width: NotchGeometry.timerBadgeWidth + 40
        ))
        // Same glyphs either way: if the narrow one truncated, the ink
        // would differ beyond the extra padding. Compare the rendered text
        // by measuring instead of by pixel equality.
        let measured = NSAttributedString(
            string: TimerDisplay.widestText,
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)]
        ).size().width
        #expect(measured <= NotchGeometry.timerBadgeWidth)
    }

    // MARK: - The slot's width and its content are one decision

    /// Whether any pixel in `bitmap` carries `marker`'s hue. Deliberately
    /// generous about exact channel values, the way `BadgeRenderingTests`'
    /// `paintedBox` is: edges are blends, only the interior has to be
    /// recognisably the marker.
    private static func contains(_ bitmap: NSBitmapImageRep, _ marker: NSColor) -> Bool {
        let want = marker.usingColorSpace(.deviceRGB)!
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let raw = bitmap.colorAt(x: x, y: y),
                      let c = raw.usingColorSpace(.deviceRGB),
                      c.alphaComponent > 0.5,
                      abs(c.redComponent   - want.redComponent)   < 0.2,
                      abs(c.greenComponent - want.greenComponent) < 0.2,
                      abs(c.blueComponent  - want.blueComponent)  < 0.2
                else { continue }
                return true
            }
        }
        return false
    }

    /// The slot's width and its content must be decided by the same rule.
    /// A timer that reserves 44pt and then draws an album cover is the
    /// "two derivations of one thing" bug in a new costume.
    ///
    /// `NotchShape.badgeSlot` replaced `badgeWidth` on this branch: an
    /// identity rather than a width, so the drawn content and the reserved
    /// width read the same answer instead of two independent constants —
    /// the first two assertions below pin that pure-function side.
    ///
    /// The pure function alone would not catch `NotchRootView`'s `.closed`
    /// overlay drawing `NowPlayingBadgeView` for `.timer` too: `badgeSlot`
    /// itself is unaffected by that bug. The third assertion renders the
    /// actual view and checks the drawn branch directly, so a wiring
    /// mistake there — not just a slot-identity mistake — fails this test.
    @Test func aRunningTimerTakesTheSlotFromPlayingMedia() throws {
        let now = Date()
        let state = AppState()
        state.setGeometry(
            anchor: .notch(CGRect(x: 2090, y: 1118, width: 230, height: 38)),
            panelFrame: CGRect(x: 1895, y: 896, width: 620, height: 260)
        )
        state.nowPlaying = TrackSnapshot(title: "T", artist: "A", isPlaying: true)
        state.nowPlayingArtwork = SolidArtwork.red
        state.countdown = Countdown(duration: 600, startingAt: now)

        #expect(NotchShape.badgeSlot(
            countdown: state.countdown, nowPlaying: state.nowPlaying, at: now
        ) == .timer)
        #expect(NotchShape.badgeSlot(
            countdown: state.countdown, nowPlaying: state.nowPlaying, at: now
        ).width == NotchGeometry.timerBadgeWidth)

        let renderer = ImageRenderer(
            content: NotchRootView(app: state, now: now)
                .frame(width: 620, height: 260)
        )
        renderer.scale = 1
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))

        #expect(!Self.contains(bitmap, .systemRed))
    }
}
