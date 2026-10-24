import AppKit
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// Peeks reach VoiceOver from the place they are applied.
///
/// What to say, and when to say nothing, is `PeekAnnouncementTests`'s; this
/// pins only the connection — that both paths into `.peek` (a new peek and
/// a re-check of a showing one) consult it, and that a peek the arbiter
/// declines to show is not announced anyway.
@MainActor
struct PeekAnnouncementWiringTests {

    private let song = TrackSnapshot(title: "Blue in Green", artist: "Miles Davis", isPlaying: true)

    private func makeDelegate() -> (AppDelegate, () -> [String]) {
        let delegate = NotchedDelegate.make()
        delegate.powerTTLDelay = .zero
        delegate.timerDoneTTLDelay = .zero
        var spoken: [String] = []
        delegate.announce = { spoken.append($0) }
        return (delegate, { spoken })
    }

    @Test func aPowerPeekIsAnnounced() {
        let (delegate, spoken) = makeDelegate()
        delegate.showPowerPeek(.unplugged(level: 50))
        #expect(delegate.state.state == .peek(.power(.unplugged(level: 50))))
        #expect(spoken() == ["On Battery, 50%"])
    }

    @Test func aFinishedTimerIsAnnounced() throws {
        let (delegate, spoken) = makeDelegate()
        let countdown = try #require(Countdown(duration: 600, startingAt: Date().addingTimeInterval(-600)))
        delegate.timerDidFinish(countdown)
        #expect(spoken() == ["10-minute timer finished"])
    }

    /// The panel is a deliberate state the peek path declines to interrupt;
    /// a peek that was never shown must not be heard either.
    @Test func aPeekThatIsNotShownIsNotAnnounced() {
        let (delegate, spoken) = makeDelegate()
        delegate.state.transition(to: .open(.shelf))
        delegate.showPowerPeek(.unplugged(level: 50))
        #expect(spoken().isEmpty)
    }

    /// A track change with nothing peeking is the badge's business, not an
    /// announcement — otherwise every song would be read out unasked.
    @Test func aTrackChangeWithNoPeekShowingIsSilent() {
        let (delegate, spoken) = makeDelegate()
        delegate.nowPlayingDidChange(song)
        #expect(spoken().isEmpty)
    }

    /// Hovered open, the peek is silent -- the hover asked for it; the pause
    /// that follows re-applies it through the re-check, silently; the next
    /// track, which nobody asked for, is spoken.
    @Test func theNowPlayingPeekIsAnnouncedWhenShownAndOnANewTrackOnly() {
        let (delegate, spoken) = makeDelegate()
        delegate.nowPlayingDidChange(song)
        delegate.state.isHovering = true
        delegate.hoverView?.onDwell()
        #expect(delegate.state.state == .peek(.nowPlaying(song)))

        var paused = song
        paused.isPlaying = false
        delegate.nowPlayingDidChange(paused)
        #expect(delegate.state.state == .peek(.nowPlaying(paused)))

        let next = TrackSnapshot(title: "So What", artist: "Miles Davis", isPlaying: true)
        delegate.nowPlayingDidChange(next)

        #expect(spoken() == ["Now playing: So What by Miles Davis"])
    }

    /// Resting on the notch again after it collapsed is another hover, not
    /// news: the same track is not read out on every rest.
    @Test func hoveringTheSameTrackAgainIsSilent() {
        let (delegate, spoken) = makeDelegate()
        delegate.nowPlayingDidChange(song)
        for _ in 0..<2 {
            delegate.state.isHovering = true
            delegate.hoverView?.onDwell()
            #expect(delegate.state.state == .peek(.nowPlaying(song)))
            delegate.state.isHovering = false
            delegate.state.transition(to: .closed)
        }
        #expect(spoken().isEmpty)
    }

    /// The re-check that reveals a power peek under a lapsing timer is a
    /// new peek on screen, and is spoken. The power event recorded while
    /// the timer held the slot changed nothing visible, so it was not.
    @Test func aPeekRevealedByTheReCheckIsAnnounced() async throws {
        let (delegate, spoken) = makeDelegate()
        var clock: TimeInterval = 1_000
        delegate.now = { clock }

        let countdown = try #require(Countdown(duration: 300, startingAt: Date().addingTimeInterval(-300)))
        delegate.timerDidFinish(countdown)
        delegate.showPowerPeek(.pluggedIn(level: 40))
        #expect(spoken() == ["5-minute timer finished"])

        // The timer's TTL lapses with a fresh power event live underneath.
        clock += PeekArbiter.timerDoneTTL + 1
        delegate.arbiter.recordPower(.pluggedIn(level: 40), now: clock)
        await delegate.peekTTLTask?.value

        #expect(delegate.state.state == .peek(.power(.pluggedIn(level: 40))))
        #expect(spoken() == ["5-minute timer finished", "Plugged In, 40%"])
    }
}
