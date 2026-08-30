import AppKit
import SwiftUI
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// The one place in this suite that actually renders a view.
///
/// Every other view here is tested through the pure function it leans on,
/// and that is exactly how the ambient peek shipped broken: `NotchRootView`
/// handled `.peek(.hud)` and let `.peek(.nowPlaying)` fall through to
/// `default`, which draws the literal string "CreativeNotch". Nothing about
/// `NowPlayingLabel` — the pure part — was wrong, so no pure test could
/// have caught it. What was missing was a `case` in a `switch`, and the
/// only evidence that a `case` exists is what gets drawn.
///
/// `ImageRenderer` rasterises offscreen with no window and no window
/// server, so these stay as cheap and headless as the rest of the suite.
/// The assertions are deliberately *comparative* rather than absolute:
/// nothing here claims to know what the pixels should be, only that the
/// now-playing peek draws something other than the fallback label, and
/// something that changes when the track changes.
@MainActor
struct PeekRenderingTests {

    private static let playing = TrackSnapshot(
        title: "Blinding Lights", artist: "The Weeknd", isPlaying: true
    )

    /// A peek whose content is NOT now-playing, so it renders through the
    /// `default` branch — the literal app name. This is the exact image the
    /// bug produced over playing music.
    private static let appNameFallback: PeekContent = .dragTarget

    private static func peekPixels(_ content: PeekContent) -> Data? {
        let state = AppState()
        state.transition(to: .peek(content))

        let renderer = ImageRenderer(
            content: NotchRootView(app: state).frame(width: 400, height: 120)
        )
        renderer.scale = 1
        guard
            let image = renderer.nsImage,
            let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff)
        else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    /// Without this, "the two images differ" would be worthless: if the
    /// renderer produced noise, every comparison below would pass no matter
    /// what the view did.
    @Test func renderingTheSamePeekTwiceIsIdentical() throws {
        let once = try #require(Self.peekPixels(.nowPlaying(Self.playing)))
        let twice = try #require(Self.peekPixels(.nowPlaying(Self.playing)))

        #expect(once == twice)
    }

    /// The bug: hovering the closed notch with music playing drew the app
    /// name. Delete `case .peek(.nowPlaying(...))` from `NotchRootView` and
    /// both of these render the same "CreativeNotch" text, so this fails.
    @Test func theNowPlayingPeekDoesNotDrawTheAppName() throws {
        let track = try #require(Self.peekPixels(.nowPlaying(Self.playing)))
        let appName = try #require(Self.peekPixels(Self.appNameFallback))

        #expect(track != appName)
    }

    /// And what it draws is the *track*, not some fixed now-playing chrome:
    /// two different tracks must not rasterise identically.
    @Test func theNowPlayingPeekDrawsTheTrackItself() throws {
        let weeknd = try #require(Self.peekPixels(.nowPlaying(Self.playing)))
        let other = try #require(Self.peekPixels(.nowPlaying(
            TrackSnapshot(title: "Redbone", artist: "Childish Gambino", isPlaying: true)
        )))

        #expect(weeknd != other)
    }

    /// The peek and the panel header must not drift apart, so the peek is
    /// built from `NowPlayingLabel.text(for:)` — including its
    /// missing-artist rule. A peek that showed the title alone would
    /// render the same image for both of these.
    @Test func thePeekUsesTheSharedLabelIncludingItsArtistRule() throws {
        let withArtist = try #require(Self.peekPixels(.nowPlaying(
            TrackSnapshot(title: "Some Episode", artist: "A Host", isPlaying: true)
        )))
        let withoutArtist = try #require(Self.peekPixels(.nowPlaying(
            TrackSnapshot(title: "Some Episode", artist: "", isPlaying: true)
        )))

        #expect(withArtist != withoutArtist)
    }
}
