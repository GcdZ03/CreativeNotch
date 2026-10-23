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

// MARK: - A peek already on screen

private let paused = TrackSnapshot(title: "Song", artist: "Artist", isPlaying: false)

/// Pressing Pause in the now-playing peek must not collapse it under the
/// pointer, or Play is unreachable from the peek that offered Pause.
@Test func aPausedTrackIsHeldWhileThePointerIsOverItsPeek() {
    var a = PeekArbiter()
    a.setNowPlaying(paused)
    #expect(a.content(now: 0, replacing: .nowPlaying(track), pointerInside: true) == .nowPlaying(paused))
}

/// Held only under the pointer: once it leaves, a paused track is gone.
@Test func aPausedTrackIsNotHeldWithoutThePointer() {
    var a = PeekArbiter()
    a.setNowPlaying(paused)
    #expect(a.content(now: 0, replacing: .nowPlaying(track), pointerInside: false) == nil)
}

/// And held only by a now-playing peek. Hovering an expiring power peek
/// does not resurrect a track that was already paused.
@Test func aPausedTrackIsNotRevealedUnderAnExpiringPowerPeek() {
    var a = PeekArbiter()
    a.setNowPlaying(paused)
    #expect(a.content(now: 0, replacing: .power(.unplugged(level: 66)), pointerInside: true) == nil)
}

/// Ambient content is fallen back to only with the pointer there to ask for
/// it. Otherwise it sat open indefinitely after a power peek.
@Test func ambientContentIsNotFallenBackToWithoutThePointer() {
    var a = PeekArbiter()
    a.setNowPlaying(track)
    #expect(a.content(now: 0, replacing: .power(.unplugged(level: 66)), pointerInside: false) == nil)
    #expect(a.content(now: 0, replacing: .power(.unplugged(level: 66)), pointerInside: true) == .nowPlaying(track))
}

/// Transient content is unaffected: it was never asked for, and it expires.
@Test func transientContentIgnoresThePointer() {
    var a = PeekArbiter()
    a.setNowPlaying(track)
    a.recordPower(.unplugged(level: 66), now: 100)
    #expect(a.content(now: 100, replacing: .nowPlaying(track), pointerInside: false) == .power(.unplugged(level: 66)))
}
