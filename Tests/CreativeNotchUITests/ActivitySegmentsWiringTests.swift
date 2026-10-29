import AppKit
import Foundation
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// Several activities beside the notch, joined to the app (2026-10-29): the
/// three rects grow by every segment, and a hover or a click lands on the
/// segment under the pointer.
@MainActor
struct ActivitySegmentsWiringTests {

    private static let playing = TrackSnapshot(title: "Song", artist: "Band", isPlaying: true)

    private func musicAndTimer() -> AppDelegate {
        let delegate = NotchedDelegate.make(countdown: Countdown(duration: 600, startingAt: Date()))
        delegate.nowPlayingDidChange(Self.playing)
        delegate.countdownDidChange(delegate.state.countdown)
        return delegate
    }

    /// Puts the pointer on `slot`'s segment, in screen coordinates.
    private func point(_ delegate: AppDelegate, at slot: BadgeSlot) throws {
        let segments = NotchShape.badgeSegments(
            delegate.currentBadgeSlots, anchor: delegate.state.anchor, panelFrame: delegate.state.panelFrame
        )
        let rect = try #require(segments.first { $0.slot == slot }?.rect)
        let frame = delegate.state.panelFrame
        let screen = CGPoint(x: frame.minX + rect.midX, y: frame.minY + rect.midY)
        delegate.pointerLocation = { screen }
    }

    private func expectRectsAgree(_ delegate: AppDelegate, sourceLocation: SourceLocation = #_sourceLocation) {
        let drawn = NotchRootView.drawnRect(for: delegate.state)
        #expect(drawn.size == delegate.acceptedRect.size, sourceLocation: sourceLocation)
        #expect(drawn.minX == delegate.acceptedRect.minX, sourceLocation: sourceLocation)
        #expect(delegate.hoverView?.trackingRect == delegate.acceptedRect, sourceLocation: sourceLocation)
    }

    // MARK: - The pointer finds its segment

    @Test func thePointerIsOverTheSegmentItRestsOn() throws {
        let delegate = musicAndTimer()
        try point(delegate, at: .timer)
        #expect(delegate.segmentUnderPointer == .timer)
        try point(delegate, at: .nowPlaying)
        #expect(delegate.segmentUnderPointer == .nowPlaying)
    }

    // MARK: - Hover

    @Test func hoveringTheTimerShowsTheTimer() throws {
        let delegate = musicAndTimer()
        try point(delegate, at: .timer)
        delegate.hoverView?.onDwell()
        #expect(delegate.state.state == .peek(.timer))
    }

    @Test func hoveringTheMusicStillShowsTheMusic() throws {
        let delegate = musicAndTimer()
        try point(delegate, at: .nowPlaying)
        delegate.hoverView?.onDwell()
        #expect(delegate.state.state == .peek(.nowPlaying(Self.playing)))
    }

    /// With open on hover, the segment's own tab opens.
    @Test func withOpenOnHoverTheTimersSegmentOpensTheTimerTab() throws {
        let delegate = musicAndTimer()
        delegate.state.onSetHoverBehaviour?(HoverBehaviour(opensOnHover: true))
        try point(delegate, at: .timer)
        delegate.hoverView?.onDwell()
        #expect(delegate.state.state == .open(.timer))
    }

    // MARK: - Click

    @Test func clickingTheTimerOpensTheTimerTab() throws {
        let delegate = musicAndTimer()
        delegate.state.timerMode = .stopwatch
        try point(delegate, at: .timer)
        NotchRootView.handleTap(app: delegate.state)
        #expect(delegate.state.state == .open(.timer))
        #expect(delegate.state.timerMode == .timer, "the countdowns, not the stopwatch")
    }

    @Test func clickingTheStopwatchOpensItsMode() throws {
        let delegate = NotchedDelegate.make()
        delegate.applyStopwatch(.start)
        try point(delegate, at: .stopwatch)
        NotchRootView.handleTap(app: delegate.state)
        #expect(delegate.state.state == .open(.timer))
        #expect(delegate.state.timerMode == .stopwatch)
    }

    /// Music has no tab of its own: a click there opens the panel as before.
    @Test func clickingTheMusicOpensTheLastTab() throws {
        let delegate = musicAndTimer()
        let last = delegate.state.lastOpenTab
        try point(delegate, at: .nowPlaying)
        NotchRootView.handleTap(app: delegate.state)
        #expect(delegate.state.state == .open(last))
    }

    // MARK: - The stopwatch's segment

    /// Starting the stopwatch adds its segment, and resetting it takes the
    /// segment away, in all three rects.
    @Test func theStopwatchsSegmentComesAndGoesWithIt() {
        let delegate = NotchedDelegate.make()
        let idle = delegate.acceptedRect.width

        delegate.applyStopwatch(.start)
        #expect(delegate.currentBadgeSlots == [.stopwatch])
        #expect(delegate.acceptedRect.width == idle + NotchGeometry.stopwatchBadgeWidth)
        expectRectsAgree(delegate)

        delegate.applyStopwatch(.pause)
        delegate.applyStopwatch(.reset)
        #expect(delegate.currentBadgeSlots.isEmpty)
        #expect(delegate.acceptedRect.width == idle)
        expectRectsAgree(delegate)
    }

    @Test func everythingAtOnceGrowsAllThreeRectsTogether() {
        let delegate = musicAndTimer()
        delegate.applyStopwatch(.start)
        delegate.state.captureUse = CaptureUse(microphone: true)
        delegate.downloadsDidChange(DownloadSummary(count: 1, percent: 10, leadingName: "a.zip"))
        // As many as the room past the notch holds, from the notch out, and
        // the privacy dot always.
        let slots = delegate.currentBadgeSlots
        #expect(slots.totalWidth <= NotchShape.badgeRoom(anchor: delegate.state.anchor, panelFrame: delegate.state.panelFrame))
        #expect(slots.last == .capture)
        #expect(slots.first == .nowPlaying)
        expectRectsAgree(delegate)
    }
}
