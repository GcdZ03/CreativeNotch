import AppKit
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// The progress bar's seek reaches the media route, from the peek and the
/// panel alike (2026-10-18) — never the real player from a test.
@MainActor
struct SeekWiringTests {

    private static let track = TrackSnapshot(
        title: "Song", artist: "Band", isPlaying: true,
        position: PlaybackPosition(elapsed: 10, duration: 200, anchoredAt: Date())
    )

    @Test func thePeeksBarSeeksThroughAppState() throws {
        let app = AppState()
        app.setGeometry(anchor: .notch(CGRect(x: 0, y: 0, width: 230, height: 38)), panelFrame: .zero)
        var seeks: [TimeInterval] = []
        app.onSeek = { seeks.append($0) }

        let peek = NotchRootView.nowPlayingPeek(for: app, track: Self.track)
        // Unwrapped first: calling the macro's result directly crashes the
        // Swift 6.3 compiler (an assertion in the constraint solver).
        let seek = try #require(peek.onSeek)
        seek(42)

        #expect(seeks == [42])
    }

    /// The delegate wires the verb only where the transport controls work,
    /// the same gate the buttons sit behind.
    @Test func theDelegateWiresSeekingWithTheControls() {
        let d = NotchedDelegate.make()
        d.switchboard.setEnabled(true, for: .mediaControls)
        #expect((d.state.onSeek != nil) == d.state.showsMediaControls)
    }

    /// Looked up, never called: the function a seek goes through is still
    /// in this macOS.
    @Test func theSeekFunctionStillExists() {
        #expect(MediaRemoteBridge.canSeek)
    }

    /// A bar handed no seek is display-only — the paused-render tests and
    /// any view without controls draw it without a drag target.
    @Test func withoutASeekTheBarIsDisplayOnly() throws {
        let position = try #require(Self.track.position)
        #expect(PlaybackProgressView(position: position, isPlaying: true).onSeek == nil)
    }
}
