import AppKit
import Foundation
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// The lyrics module joined to the app: switch, controller, the strip under
/// the closed notch, and the region that accepts clicks (spec 2026-10-29).
///
/// Every request goes to a scripted fake: no test sends a title anywhere.
@MainActor
struct LyricsWiringTests {

    private final class Service: @unchecked Sendable {
        static let found = #"{"instrumental":false,"syncedLyrics":"[00:10.00] one\n[00:20.00] two"}"#
        private(set) var asked: [URL] = []
        func fetch(_ url: URL) -> (status: Int, body: Data)? {
            asked.append(url)
            return (200, Data(Self.found.utf8))
        }
    }

    private func makeDelegate() -> (AppDelegate, Service) {
        let service = Service()
        let delegate = AppDelegate()
        delegate.shelfTrash = TestTrash.shelf
        delegate.preferencesDefaults = TestDefaults.isolated("lyrics")
        delegate.growthDelay = .zero
        delegate.playChime = { _ in }
        delegate.performHaptic = {}
        delegate.announce = { _ in }
        delegate.pointerLocation = { CGPoint(x: -10_000, y: -10_000) }
        delegate.screenDescriptors = { [] }
        delegate.fetchLyrics = { url in service.fetch(url) }
        delegate.installOutsideClickMonitor = { _ in nil }
        delegate.takeKey = {}
        delegate.relinquishKey = {}
        delegate.install(metrics: NotchedDelegate.metrics)
        delegate.clipboard?.poller.scheduleTimer = { _, _ in nil }
        delegate.clipboard?.poller.cancelTimer = { _ in }
        delegate.media?.supervisor.startHelper = {}
        delegate.media?.supervisor.stopHelper = {}
        // Parks every line's one-shot: nothing here waits out a real one.
        // And a pinned clock: under a loaded parallel run a test can take
        // seconds, and the real one would carry the song past its last line.
        delegate.lyrics?.sleep = { _ in try? await Task.sleep(for: .seconds(86_400)) }
        delegate.lyrics?.now = { Self.t0 }
        return (delegate, service)
    }

    private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func track(playing: Bool = true) -> TrackSnapshot {
        TrackSnapshot(
            title: "Song", artist: "Band", album: "Album", isPlaying: playing,
            position: PlaybackPosition(elapsed: 12, duration: 200, anchoredAt: Self.t0)
        )
    }

    private func play(_ delegate: AppDelegate, _ snapshot: TrackSnapshot) async {
        delegate.nowPlayingDidChange(snapshot)
        await delegate.lyrics?.lookupTask?.value
    }

    /// The drawn shape and the region that accepts clicks and hover agree.
    private func expectRectsAgree(_ delegate: AppDelegate, sourceLocation: SourceLocation = #_sourceLocation) {
        let drawn = NotchRootView.drawnRect(for: delegate.state)
        #expect(drawn.size == delegate.acceptedRect.size, sourceLocation: sourceLocation)
        #expect(drawn.minX == delegate.acceptedRect.minX, sourceLocation: sourceLocation)
        #expect(delegate.hoverView?.trackingRect == delegate.acceptedRect, sourceLocation: sourceLocation)
    }

    // MARK: - Ships off

    /// A fresh install applies its preferences and lyrics stay off: a track
    /// playing at launch is sent nowhere.
    @Test func aFreshLaunchSendsNothing() async {
        let (delegate, service) = makeDelegate()
        delegate.switchboard.apply()
        await play(delegate, track())

        #expect(delegate.state.preferences.lyrics == false)
        #expect(service.asked.isEmpty)
        #expect(delegate.state.lyrics == nil)
    }

    /// The default seam answers nothing; only the real launch replaces it.
    @Test func aBareDelegateNeverReachesTheService() async {
        let delegate = AppDelegate()
        let url = URL(string: "https://lrclib.net/api/get")!
        #expect(await delegate.fetchLyrics(url) == nil)
    }

    /// Switched on with a track already playing: it is looked up at once.
    @Test func switchingOnLooksUpWhatIsPlaying() async {
        let (delegate, service) = makeDelegate()
        delegate.switchboard.apply()
        delegate.nowPlayingDidChange(track())
        delegate.switchboard.setEnabled(true, for: .lyrics, persist: true)
        await delegate.lyrics?.lookupTask?.value

        #expect(service.asked.count == 1)
        #expect(delegate.state.lyrics == LyricsText(current: "one"))
        #expect(delegate.preferencesStore.load().lyrics == true)
    }

    // MARK: - The strip

    /// The strip grows the closed notch down by a line, and the region that
    /// accepts clicks and hover grows with it -- a drawn line clicks fell
    /// through would be this project's only Critical bug again.
    @Test func theStripGrowsWhatAcceptsClicksWithTheDrawing() async {
        let (delegate, _) = makeDelegate()
        delegate.switchboard.apply()
        delegate.switchboard.setEnabled(true, for: .lyrics)
        delegate.nowPlayingDidChange(TrackSnapshot(title: "Song", artist: "Band", isPlaying: true))
        let withoutStrip = delegate.acceptedRect

        await play(delegate, track())

        #expect(delegate.state.showsLyricsLine)
        #expect(delegate.acceptedRect.height == withoutStrip.height + NotchGeometry.lyricsLineHeight)
        #expect(delegate.acceptedRect.maxY == withoutStrip.maxY)
        expectRectsAgree(delegate)
    }

    /// Paused, the strip goes with the badge, and the region shrinks with it.
    @Test func pausingTakesTheStripAway() async {
        let (delegate, _) = makeDelegate()
        delegate.switchboard.apply()
        delegate.switchboard.setEnabled(true, for: .lyrics)
        await play(delegate, track())
        let withStrip = delegate.acceptedRect.height

        delegate.nowPlayingDidChange(track(playing: false))

        #expect(delegate.state.showsLyricsLine == false)
        #expect(delegate.acceptedRect.height == withStrip - NotchGeometry.lyricsLineHeight)
        expectRectsAgree(delegate)
    }

    /// Off withdraws the line and shrinks the notch at once.
    @Test func switchingOffTakesTheStripAway() async {
        let (delegate, _) = makeDelegate()
        delegate.switchboard.apply()
        delegate.switchboard.setEnabled(true, for: .lyrics)
        delegate.nowPlayingDidChange(TrackSnapshot(title: "Song", artist: "Band", isPlaying: true))
        let withoutStrip = delegate.acceptedRect
        await play(delegate, track())

        delegate.switchboard.setEnabled(false, for: .lyrics)

        #expect(delegate.state.lyrics == nil)
        #expect(delegate.lyrics?.boundaryTask == nil)
        #expect(delegate.lyrics?.cachedAnswers == 0)
        #expect(delegate.acceptedRect == withoutStrip)
        expectRectsAgree(delegate)
    }

    /// The music peek grows by the lyrics row, and so does what accepts the
    /// pointer, or the row would be a strip of the peek that closes it.
    @Test func theMusicPeekGrowsByTheRow() async {
        let (delegate, _) = makeDelegate()
        delegate.switchboard.apply()
        delegate.switchboard.setEnabled(true, for: .lyrics)
        await play(delegate, track())

        delegate.state.transition(to: .peek(.nowPlaying(track())))

        let peek = NotchShape.visibleRect(
            presentation: .mediaPeek, anchor: delegate.state.anchor, panelFrame: delegate.state.panelFrame
        )
        #expect(NotchRootView.drawnRect(for: delegate.state).height == peek.height + NotchGeometry.lyricsLineHeight)
        expectRectsAgree(delegate)
    }

    // MARK: - Quitting and locking

    @Test func quittingStopsTheOneShot() async {
        let (delegate, _) = makeDelegate()
        delegate.switchboard.apply()
        delegate.switchboard.setEnabled(true, for: .lyrics)
        await play(delegate, track())
        #expect(delegate.lyrics?.boundaryTask != nil)

        delegate.switchboard.stopAll()

        #expect(delegate.lyrics?.boundaryTask == nil)
    }

    @Test func lockingStopsTheOneShot() async {
        let (delegate, _) = makeDelegate()
        delegate.switchboard.apply()
        delegate.switchboard.setEnabled(true, for: .lyrics)
        await play(delegate, track())

        delegate.switchboard.setActivity(.locked)
        #expect(delegate.lyrics?.boundaryTask == nil)

        delegate.switchboard.setActivity(.active)
        #expect(delegate.lyrics?.boundaryTask != nil)
    }

    // MARK: - Settings

    @Test func theSettingsRowSaysWhereTracksGo() throws {
        let row = try #require(PreferencesView.rows.first { $0.module == .lyrics })
        #expect(row.section == .music)
        #expect(row.detail.contains("LRCLIB"))
        #expect(row.detail.contains("title"))
    }
}
