import Foundation
import Testing
@testable import CreativeNotchCore

/// Which peek VoiceOver announces, and with what words.
///
/// A peek is a few seconds of picture in a corner of the screen nobody
/// sighted is asked to look at, let alone someone who cannot see it, so
/// each one that tells the user something new is spoken. The rules worth
/// pinning are the ones about *not* speaking: the now-playing peek is
/// re-applied on every metadata update, and an announcement per seek or
/// per pause would bury the ones that matter.
struct PeekAnnouncementTests {

    private let song = TrackSnapshot(title: "Blue in Green", artist: "Miles Davis", isPlaying: true)

    // MARK: - Words

    @Test func aFinishedTimerUsesTheSpokenCompletion() {
        let done = TimerCompletion(duration: 1500, lateness: 0)
        #expect(PeekAnnouncement.text(for: .timerDone(done)) == "25-minute timer finished")
    }

    @Test func aPowerPeekUsesThePeekTitleAndLevel() {
        #expect(PeekAnnouncement.text(for: .power(.pluggedIn(level: 80))) == "Plugged In, 80%")
        #expect(PeekAnnouncement.text(for: .power(.unplugged(level: 66))) == "On Battery, 66%")
        #expect(PeekAnnouncement.text(for: .power(.lowBattery(threshold: 20, level: 19)))
                == "Low Battery, 19%")
        #expect(PeekAnnouncement.text(for: .power(.lowPowerMode(enabled: true))) == "Low Power Mode On")
    }

    @Test func nowPlayingNamesTheTrackAndArtist() {
        #expect(PeekAnnouncement.text(for: .nowPlaying(song)) == "Now playing: Blue in Green by Miles Davis")
    }

    /// Podcasts and voice memos have no artist; no dangling "by".
    @Test func nowPlayingWithoutAnArtistNamesOnlyTheTrack() {
        let memo = TrackSnapshot(title: "Memo", artist: "", isPlaying: true)
        #expect(PeekAnnouncement.text(for: .nowPlaying(memo)) == "Now playing: Memo")
    }

    /// The drop target is the user's own drag answering back; announcing it
    /// would narrate a gesture they are in the middle of making.
    @Test func theDropTargetIsNeverAnnounced() {
        #expect(PeekAnnouncement.text(for: .dragTarget) == nil)
        #expect(PeekAnnouncement.announcement(showing: .dragTarget, replacing: nil) == nil)
    }

    // MARK: - When

    @Test func aPeekAppearingFromTheClosedNotchIsAnnounced() {
        let done = TimerCompletion(duration: 600, lateness: 0)
        #expect(PeekAnnouncement.announcement(showing: .timerDone(done), replacing: nil)
                == "10-minute timer finished")
        #expect(PeekAnnouncement.announcement(showing: .power(.unplugged(level: 50)), replacing: nil)
                == "On Battery, 50%")
        #expect(PeekAnnouncement.announcement(showing: .nowPlaying(song), replacing: nil)
                == "Now playing: Blue in Green by Miles Davis")
    }

    /// A re-check that finds the same peek still live re-applies it; that is
    /// not news.
    @Test func reapplyingTheSamePeekIsSilent() {
        let event = PeekContent.power(.lowBattery(threshold: 20, level: 19))
        #expect(PeekAnnouncement.announcement(showing: event, replacing: event) == nil)
    }

    /// One transient replacing another is news: the timer finishing over a
    /// charger peek, or the charger peek revealed when the timer's lapses.
    @Test func aDifferentPeekReplacingAnotherIsAnnounced() {
        let done = PeekContent.timerDone(.init(duration: 300, lateness: 0))
        let power = PeekContent.power(.pluggedIn(level: 40))
        #expect(PeekAnnouncement.announcement(showing: done, replacing: power) == "5-minute timer finished")
        #expect(PeekAnnouncement.announcement(showing: power, replacing: done) == "Plugged In, 40%")
        #expect(PeekAnnouncement.announcement(showing: .nowPlaying(song), replacing: power)
                == "Now playing: Blue in Green by Miles Davis")
    }

    /// Pause, play and seek all republish the snapshot into a showing peek.
    /// The track is the same track; nothing is said.
    @Test func metadataUpdatesToTheShowingTrackAreSilent() throws {
        var paused = song
        paused.isPlaying = false
        var seeked = song
        seeked.position = try #require(PlaybackPosition(elapsed: 90, duration: 300, anchoredAt: Date()))
        #expect(PeekAnnouncement.announcement(showing: .nowPlaying(paused), replacing: .nowPlaying(song)) == nil)
        #expect(PeekAnnouncement.announcement(showing: .nowPlaying(seeked), replacing: .nowPlaying(song)) == nil)
    }

    /// The next track arriving while the peek is open is what the peek is
    /// for, so it is spoken.
    @Test func aNewTrackInTheShowingPeekIsAnnounced() {
        let next = TrackSnapshot(title: "So What", artist: "Miles Davis", isPlaying: true)
        #expect(PeekAnnouncement.announcement(showing: .nowPlaying(next), replacing: .nowPlaying(song))
                == "Now playing: So What by Miles Davis")
    }
}
