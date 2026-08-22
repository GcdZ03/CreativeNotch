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
