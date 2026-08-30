import AppKit
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// Views are not unit-tested here, so the pure formatting they lean on is
/// pulled out and tested instead — plus the wiring that makes the module
/// reachable at all.
@MainActor
struct NowPlayingTests {

    private static let notched = ScreenMetrics(
        frame: CGRect(x: 1470, y: 200, width: 1470, height: 956),
        safeAreaTopInset: 38,
        auxiliaryTopLeftWidth: 620,
        auxiliaryTopRightWidth: 620,
        menuBarHeight: 38
    )

    private func makeDelegate() -> AppDelegate {
        let delegate = AppDelegate()
        delegate.growthDelay = .zero
        delegate.shelfDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CreativeNotchNowPlaying-\(UUID().uuidString)")
        delegate.install(metrics: Self.notched)
        return delegate
    }

    @Test func titleAndArtistAreJoined() {
        let s = TrackSnapshot(title: "Beauty And A Beat", artist: "Justin Bieber", isPlaying: true)
        #expect(NowPlayingLabel.text(for: s) == "Beauty And A Beat — Justin Bieber")
    }

    /// Some tracks genuinely have no artist — podcasts, voice memos. A
    /// dangling separator would look broken.
    @Test func aMissingArtistDropsTheSeparator() {
        let s = TrackSnapshot(title: "Some Episode", artist: "", isPlaying: true)
        #expect(NowPlayingLabel.text(for: s) == "Some Episode")
    }

    @Test func installingCreatesTheMediaController() {
        #expect(makeDelegate().media != nil)
    }

    /// The panel header reads this; left unwired it would always be empty.
    @Test func theControllerPublishesIntoAppState() throws {
        let delegate = makeDelegate()
        let media = try #require(delegate.media)
        media.handle(line: #"{"title":"X","artist":"Y","album":"","playing":true,"contentID":"i"}"#)

        #expect(delegate.state.nowPlaying?.title == "X")
    }

    /// The ambient peek is the scope decision this module was built for:
    /// playing media must reach the arbiter, or hovering shows nothing.
    @Test func playingMediaReachesThePeekArbiter() throws {
        let delegate = makeDelegate()
        let media = try #require(delegate.media)
        media.handle(line: #"{"title":"X","artist":"Y","album":"","playing":true,"contentID":"i"}"#)

        #expect(delegate.arbiter.content(now: 0) == .nowPlaying(
            TrackSnapshot(title: "X", artist: "Y", isPlaying: true)
        ))
    }

    /// Paused media is not ambient content — the notch should be quiet.
    @Test func pausedMediaDoesNotPeek() throws {
        let delegate = makeDelegate()
        let media = try #require(delegate.media)
        media.handle(line: #"{"title":"X","artist":"Y","album":"","playing":false,"contentID":"i"}"#)

        #expect(delegate.arbiter.content(now: 0) == nil)
    }

    /// Spec section 5: once the helper degrades the panel shows no header —
    /// and the peek must go with it. The arbiter keeps whatever it was last
    /// told, so a snapshot left behind there would keep peeking a track
    /// hours after the helper stopped existing. Driven through the
    /// supervisor's real exit path, so it also proves `onDegraded` is
    /// actually wired rather than merely assignable.
    @Test func degradingClearsTheHeaderAndThePeek() throws {
        let delegate = makeDelegate()
        let media = try #require(delegate.media)
        media.supervisor.startHelper = {}
        media.supervisor.stopHelper = {}
        var pending: (@MainActor () -> Void)?
        media.supervisor.scheduleRetry = { _, work in pending = work }

        media.handle(line: #"{"title":"X","artist":"Y","album":"","playing":true,"contentID":"i"}"#)
        #expect(delegate.state.nowPlaying != nil)
        #expect(delegate.arbiter.content(now: 0) != nil)

        for _ in 1...(HelperBackoff.maxAttempts + 1) {
            media.supervisor.helperExited(status: 1)
            pending?()
        }

        #expect(media.supervisor.isDegraded)
        #expect(delegate.state.nowPlaying == nil)
        #expect(delegate.state.nowPlayingArtwork == nil)
        #expect(delegate.arbiter.content(now: 0) == nil)
    }
}
