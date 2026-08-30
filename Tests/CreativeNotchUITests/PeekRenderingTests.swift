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

    /// Renders `NowPlayingPeekView` on its own, NOT through
    /// `NotchRootView`.
    ///
    /// Going through the root view was the first attempt and it produced a
    /// test that could not fail: switching the anchor to `.notch` also
    /// changes the drawn panel *shape*, so the two images differed whether
    /// or not the text respected the gap. Rendering the peek view directly
    /// is what isolates the only variable that matters.
    private static func peekViewPixels(notchGap: CGFloat, artwork: Data? = nil) -> Data? {
        let renderer = ImageRenderer(
            content: NowPlayingPeekView(
                track: Self.playing, artwork: artwork, notchGap: notchGap
            )
            .frame(width: 400, height: 32)
        )
        renderer.scale = 1
        guard
            let image = renderer.nsImage,
            let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff)
        else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    /// A notched Mac must not draw the track down the middle of the band —
    /// that is where the camera housing is, and the text would sit behind
    /// it. `HUDView` already learned this the expensive way: a centred slab
    /// put 72% of its level bar under the notch.
    ///
    /// Make `NowPlayingPeekView` ignore `notchGap` and both renders become
    /// identical, so this fails.
    @Test func theNowPlayingPeekLaysOutAroundAPhysicalNotch() throws {
        let notchless = try #require(Self.peekViewPixels(notchGap: 0))
        let notched = try #require(Self.peekViewPixels(notchGap: 179))

        #expect(notchless != notched)
    }

    /// And the gap tracks the real notch width rather than being a fixed
    /// inset — a 14" and a 16" Mac have different notches.
    @Test func theGapFollowsTheNotchWidth() throws {
        let narrow = try #require(Self.peekViewPixels(notchGap: 120))
        let wide = try #require(Self.peekViewPixels(notchGap: 200))

        #expect(narrow != wide)
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

    /// The peek carries a cover too, and it has to survive on both of
    /// `NowPlayingPeekView`'s layouts — the split one that reads around a
    /// physical notch, and the single centred line everywhere else. Delete
    /// `cover` from either branch and that branch renders the same image
    /// with artwork as without.
    ///
    /// Rendered directly rather than through `NotchRootView`, for the
    /// reason `peekViewPixels` gives above: only the artwork changes
    /// between these two, so a difference can only come from the cover.
    @Test func thePeekDrawsItsCoverInTheNotchedLayout() throws {
        let bare = try #require(Self.peekViewPixels(notchGap: 179))
        let withCover = try #require(Self.peekViewPixels(notchGap: 179, artwork: SolidArtwork.red))

        #expect(bare != withCover)
    }

    @Test func thePeekDrawsItsCoverInTheCentredLayout() throws {
        let bare = try #require(Self.peekViewPixels(notchGap: 0))
        let withCover = try #require(Self.peekViewPixels(notchGap: 0, artwork: SolidArtwork.red))

        #expect(bare != withCover)
    }

    /// And it is the track's own art, not a fixed tile that appears
    /// whenever the cache is non-empty.
    @Test func thePeekCoverIsTheArtworkItWasHanded() throws {
        let red = try #require(Self.peekViewPixels(notchGap: 179, artwork: SolidArtwork.red))
        let blue = try #require(Self.peekViewPixels(notchGap: 179, artwork: SolidArtwork.blue))

        #expect(red != blue)
    }
}

/// The other half of the notch gap: not whether the peek *honours* it, but
/// whether `NotchRootView` *supplies* the right one.
///
/// `PeekRenderingTests` above own the first half, and deliberately render
/// `NowPlayingPeekView` on its own to get it — `peekViewPixels` records
/// why going through the root view produced a test that could not fail.
/// The cost of that isolation was this gap: replacing the argument with
/// `notchGap: 0` left all 525 tests green.
///
/// So these do not render at all. `NotchRootView.nowPlayingPeek(for:track:)`
/// is the peek exactly as `body` builds it, which puts the argument
/// somewhere a plain `#expect` can read — no pixels, no panel shape, no
/// second variable moving underneath the assertion. This is the regression
/// class that has already cost this project twice: `HUDView`'s centred slab
/// put 72% of its level bar behind the notch, and commit `dfe9142`.
/// (Follow-up F2.)
@MainActor
struct PeekNotchGapWiringTests {

    private static let track = TrackSnapshot(
        title: "Blinding Lights", artist: "The Weeknd", isPlaying: true
    )
    private static let panel = CGRect(x: 0, y: 0, width: 600, height: 200)

    private static func app(anchor: CreativeNotchCore.Anchor) -> AppState {
        let state = AppState()
        state.setGeometry(anchor: anchor, panelFrame: panel)
        return state
    }

    /// On a notched Mac the peek must be handed the real notch width, so
    /// the title and artist sit in the ears either side of the camera
    /// housing. Hard-code the argument to `0` and this goes red.
    @Test func theRootViewHandsThePeekTheRealNotchWidth() {
        let notch = CGRect(x: 2090, y: 1118, width: 230, height: 38)
        let state = Self.app(anchor: .notch(notch))

        let peek = NotchRootView.nowPlayingPeek(for: state, track: Self.track)

        #expect(peek.notchGap == notch.width)
    }

    /// And it is the anchor's width, not a constant that happens to match
    /// one machine: a 14" and a 16" Mac have different notches, and an
    /// external display attached to either has none.
    @Test func theGapTracksTheAnchorRatherThanAFixedInset() {
        let wide = Self.app(anchor: .notch(CGRect(x: 0, y: 0, width: 230, height: 38)))
        let narrow = Self.app(anchor: .notch(CGRect(x: 0, y: 0, width: 179, height: 33)))

        #expect(NotchRootView.nowPlayingPeek(for: wide, track: Self.track).notchGap == 230)
        #expect(NotchRootView.nowPlayingPeek(for: narrow, track: Self.track).notchGap == 179)
    }

    /// A pill anchor has nothing to read around, and the peek's single
    /// centred line is correct there. Passing the pill's width would split
    /// a line that never needed splitting.
    @Test func aPillAnchorLeavesNoGap() {
        let state = Self.app(anchor: .pill(CGRect(x: 100, y: 0, width: 230, height: 32)))

        #expect(NotchRootView.nowPlayingPeek(for: state, track: Self.track).notchGap == 0)
    }

    /// `HUDView` reads the same named value from the same place, which is
    /// the point of naming it: the two were spelled out separately, two
    /// lines apart, and this is the assertion that they cannot drift.
    /// (Follow-up F3.)
    @Test func theNamedGapIsWhatBothPeeksAreBuiltFrom() {
        let notch = CreativeNotchCore.Anchor.notch(
            CGRect(x: 2090, y: 1118, width: 230, height: 38)
        )
        let pill = CreativeNotchCore.Anchor.pill(CGRect(x: 100, y: 0, width: 230, height: 32))

        #expect(NotchRootView.notchGap(for: notch) == 230)
        #expect(NotchRootView.notchGap(for: pill) == 0)
        #expect(
            NotchRootView.nowPlayingPeek(for: Self.app(anchor: notch), track: Self.track)
                .notchGap == NotchRootView.notchGap(for: notch)
        )
    }

    /// The seam must not quietly drop the other two arguments while it is
    /// making the gap testable — a peek built without its artwork would be
    /// a worse bug than the one this closes, and one the rendering tests
    /// could not see either, since they build the view themselves.
    @Test func theRootViewHandsThePeekTheCurrentTrackAndArtwork() {
        let state = Self.app(anchor: .notch(CGRect(x: 0, y: 0, width: 230, height: 38)))
        state.nowPlayingArtwork = SolidArtwork.red

        let peek = NotchRootView.nowPlayingPeek(for: state, track: Self.track)

        #expect(peek.track == Self.track)
        #expect(peek.artwork == SolidArtwork.red)
    }
}
