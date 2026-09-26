import Testing
@testable import CreativeNotchCore

private let track = TrackSnapshot(title: "Song", artist: "Artist", isPlaying: true)

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

/// The strictness of the expiry comparison, which no other test pins:
/// `aPowerPeekExpires` checks a moment *past* the boundary and would stay
/// green if `<` became `<=`.
@Test func aPeekIsExpiredAtExactlyTheTTLBoundary() {
    var a = PeekArbiter()
    a.recordPower(.unplugged(level: 66), now: 100)
    #expect(a.content(now: 100 + PeekArbiter.powerTTL) == nil)
}

@Test func dragPreemptsEverything() {
    var a = PeekArbiter()
    a.setNowPlaying(track)
    a.recordPower(.unplugged(level: 66), now: 100)
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

/// Now-playing is ambient wallpaper and yields to anything.
@Test func aPowerPeekOutranksNowPlaying() {
    var arbiter = PeekArbiter()
    arbiter.setNowPlaying(TrackSnapshot(title: "T", artist: "A", isPlaying: true))
    arbiter.recordPower(.unplugged(level: 66), now: 100)

    #expect(arbiter.content(now: 100) == .power(.unplugged(level: 66)))
}

/// And falls back to it, rather than to nothing — transient over ambient.
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
