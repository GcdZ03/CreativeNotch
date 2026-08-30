import Testing
@testable import CreativeNotchCore

private let track = TrackSnapshot(title: "Song", artist: "Artist", isPlaying: true)
private let volumeUp = HUDEvent(kind: .volume(0.6))

@Test func emptyArbiterShowsNothing() {
    let a = PeekArbiter()
    #expect(a.content(now: 0) == nil)
}

@Test func playingTrackIsShownAsAmbient() {
    var a = PeekArbiter()
    a.setNowPlaying(track)
    #expect(a.content(now: 0) == .nowPlaying(track))
}

@Test func pausedTrackIsNotShown() {
    var a = PeekArbiter()
    a.setNowPlaying(TrackSnapshot(title: "Song", artist: "Artist", isPlaying: false))
    #expect(a.content(now: 0) == nil)
}

@Test func hudPreemptsAmbientMedia() {
    var a = PeekArbiter()
    a.setNowPlaying(track)
    a.recordHUD(volumeUp, now: 100)
    #expect(a.content(now: 100.5) == .hud(volumeUp))
}

@Test func hudExpiresAndFallsBackToMedia() {
    var a = PeekArbiter()
    a.setNowPlaying(track)
    a.recordHUD(volumeUp, now: 100)
    #expect(a.content(now: 100 + PeekArbiter.hudTTL + 0.01) == .nowPlaying(track))
}

@Test func hudExpiresToNothingWhenNoMedia() {
    var a = PeekArbiter()
    a.recordHUD(volumeUp, now: 100)
    #expect(a.content(now: 200) == nil)
}

@Test func hudIsExpiredAtExactlyTheTTLBoundary() {
    // The implementation checks `now < hudExpiry` (strict). At now ==
    // hudExpiry the HUD must already be gone — substituting `<=` for `<`
    // would make this pass incorrectly.
    var a = PeekArbiter()
    a.recordHUD(volumeUp, now: 100)
    #expect(a.content(now: 100 + PeekArbiter.hudTTL) == nil)
}

@Test func dragPreemptsEverything() {
    var a = PeekArbiter()
    a.setNowPlaying(track)
    a.recordHUD(volumeUp, now: 100)
    a.setDragActive(true)
    #expect(a.content(now: 100.1) == .dragTarget)
}

@Test func dragHasNoTimeoutOfItsOwn() {
    var a = PeekArbiter()
    a.setDragActive(true)
    #expect(a.content(now: 99_999) == .dragTarget)
}

@Test func clearingDragRestoresWhateverWasUnderneath() {
    var a = PeekArbiter()
    a.setNowPlaying(track)
    a.setDragActive(true)
    a.setDragActive(false)
    #expect(a.content(now: 0) == .nowPlaying(track))
}

@Test func stateMapsToPresentation() {
    #expect(NotchState.closed.presentation == .closed)
    #expect(NotchState.peek(.dragTarget).presentation == .peek)
    #expect(NotchState.open(.clipboard).presentation == .expanded)
    #expect(NotchState.receiving.presentation == .expanded)
}

// MARK: - Power

/// A power peek is longer-lived than a HUD one. A HUD peek confirms
/// something the user just did and can be caught in passing; a power
/// peek tells them something they did not know.
@Test func aPowerPeekOutlivesAHUDPeek() {
    #expect(PeekArbiter.powerTTL > PeekArbiter.hudTTL)
}

@Test func aPowerEventOccupiesTheSlot() {
    var arbiter = PeekArbiter()
    arbiter.recordPower(.unplugged(level: 66), now: 100)

    #expect(arbiter.content(now: 100) == .power(.unplugged(level: 66)))
}

@Test func aPowerPeekExpires() {
    var arbiter = PeekArbiter()
    arbiter.recordPower(.unplugged(level: 66), now: 100)

    #expect(arbiter.content(now: 100 + PeekArbiter.powerTTL + 0.01) == nil)
}

/// The user pressed a key a fraction of a second ago. Preempting that
/// makes their own keypress feel dropped.
@Test func aHUDPeekOutranksAPowerPeek() {
    var arbiter = PeekArbiter()
    arbiter.recordPower(.unplugged(level: 66), now: 100)
    arbiter.recordHUD(HUDEvent(kind: .volume(0.5)), now: 100)

    #expect(arbiter.content(now: 100) == .hud(HUDEvent(kind: .volume(0.5))))
}

/// Now-playing is ambient wallpaper and yields to anything.
@Test func aPowerPeekOutranksNowPlaying() {
    var arbiter = PeekArbiter()
    arbiter.setNowPlaying(TrackSnapshot(title: "T", artist: "A", isPlaying: true))
    arbiter.recordPower(.unplugged(level: 66), now: 100)

    #expect(arbiter.content(now: 100) == .power(.unplugged(level: 66)))
}

/// And falls back to it, rather than to nothing — the same
/// transient-over-ambient model the HUD already follows.
@Test func nowPlayingReturnsWhenThePowerPeekExpires() {
    let track = TrackSnapshot(title: "T", artist: "A", isPlaying: true)
    var arbiter = PeekArbiter()
    arbiter.setNowPlaying(track)
    arbiter.recordPower(.unplugged(level: 66), now: 100)

    #expect(arbiter.content(now: 100 + PeekArbiter.powerTTL + 0.01) == .nowPlaying(track))
}

/// Dragging a file is direct manipulation and outranks everything.
@Test func aDragOutranksAPowerPeek() {
    var arbiter = PeekArbiter()
    arbiter.recordPower(.unplugged(level: 66), now: 100)
    arbiter.setDragActive(true)

    #expect(arbiter.content(now: 100) == .dragTarget)
}
