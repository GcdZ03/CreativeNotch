import CoreGraphics
import Foundation
import Testing
@testable import CreativeNotchCore

/// Several activities beside the notch at once (2026-10-29): music keeps
/// the bar nearest the notch, and every other activity gets its own segment
/// further out, in one shape.
struct BadgeSegmentsTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private let playing = TrackSnapshot(title: "T", artist: "A", isPlaying: true)
    private let paused = TrackSnapshot(title: "T", artist: "A", isPlaying: false)
    private let downloads = DownloadSummary(count: 1, percent: 42, leadingName: "a.zip")
    private func running() -> Countdown { Countdown(duration: 1500, startingAt: t0)! }
    private func lapping() -> Stopwatch { Stopwatch().started(at: t0) }

    // A real 14" MacBook, as MediaPeekShapeTests.
    private let notch = Anchor.notch(CGRect(x: 646, y: 924, width: 179, height: 32))
    private let pill = Anchor.pill(CGRect(x: 500, y: 900, width: 180, height: 32))
    private let panel = CGRect(x: 425, y: 696, width: 620, height: 260)
    private let pillPanel = CGRect(x: 280, y: 672, width: 620, height: 260)

    private func slots(
        countdown: Countdown? = nil, stopwatch: Stopwatch = Stopwatch(), nowPlaying: TrackSnapshot? = nil,
        isRecording: Bool = false, capture: CaptureUse = .none, downloads: DownloadSummary? = nil,
        hiding: Set<BadgeSlot> = []
    ) -> [BadgeSlot] {
        NotchShape.badgeSlots(
            countdown: countdown, stopwatch: stopwatch, nowPlaying: nowPlaying, isRecording: isRecording,
            capture: capture, downloads: downloads, hiding: hiding, at: t0.addingTimeInterval(60)
        )
    }

    // MARK: - Which segments, in which order

    @Test func nothingActiveIsNoSegments() {
        #expect(slots().isEmpty)
        #expect(slots(nowPlaying: paused).isEmpty, "paused music shows nothing, as before")
    }

    /// Music nearest the notch, then the timer, the stopwatch, downloads, and
    /// the privacy dot at the far end, where macOS keeps its own.
    @Test func everythingAtOnceIsInOrderFromTheNotchOut() {
        let all = slots(
            countdown: running(), stopwatch: lapping(), nowPlaying: playing,
            capture: CaptureUse(microphone: true, camera: false), downloads: downloads
        )
        #expect(all == [.nowPlaying, .timer, .stopwatch, .downloads, .capture])
    }

    /// The timer no longer takes the slot from the music: both show.
    @Test func aRunningTimerSitsBesideTheMusic() {
        #expect(slots(countdown: running(), nowPlaying: playing) == [.nowPlaying, .timer])
    }

    /// One privacy dot: this app's own recording is the more specific claim.
    @Test func aRecordingReplacesTheCaptureDot() {
        let both = slots(isRecording: true, capture: CaptureUse(microphone: false, camera: true))
        #expect(both == [.recording])
    }

    /// A stopwatch shows once started, paused or running, and goes when reset.
    @Test func aStopwatchShowsUntilReset() {
        #expect(slots(stopwatch: lapping()) == [.stopwatch])
        #expect(slots(stopwatch: lapping().paused(at: t0.addingTimeInterval(5))) == [.stopwatch])
        #expect(slots(stopwatch: Stopwatch()).isEmpty)
    }

    /// Hidden in Settings → Layout: the timer's switch covers the stopwatch.
    @Test func hiddenBadgesArePassedOver() {
        let shown = slots(countdown: running(), stopwatch: lapping(), nowPlaying: playing, downloads: downloads,
                          hiding: [.nowPlaying, .timer])
        #expect(shown == [.downloads])
    }

    /// The privacy dot cannot be hidden: it is the camera exemption's
    /// explanation and the indicator module's whole output.
    @Test func thePrivacyDotIgnoresHiding() {
        #expect(slots(isRecording: true, hiding: [.recording, .capture]) == [.recording])
    }

    /// The single most important slot is unchanged, for what still asks it.
    @Test func theFirstByPriorityIsStillTheOldSlot() {
        let s = NotchShape.badgeSlot(countdown: running(), nowPlaying: playing, at: t0.addingTimeInterval(60))
        #expect(s == .timer)
    }

    // MARK: - Width and where each segment is

    @Test func theShapeGrowsByEverySegment() {
        let all: [BadgeSlot] = [.nowPlaying, .timer]
        #expect(all.totalWidth == NotchGeometry.nowPlayingBadgeWidth + NotchGeometry.timerBadgeWidth)
        #expect([BadgeSlot]().totalWidth == 0)
    }

    /// On a notch, segments start at the housing's trailing edge and run
    /// outward, each as wide as its slot, as tall as the notch.
    @Test func onANotchSegmentsRunOutFromTheHousing() {
        let segments = NotchShape.badgeSegments([.nowPlaying, .timer], anchor: notch, panelFrame: panel)
        #expect(segments.map(\.slot) == [.nowPlaying, .timer])
        // Panel-local: the notch's trailing edge is 221 + 179 = 400.
        #expect(segments[0].rect == CGRect(x: 400, y: 228, width: 68, height: 32))
        #expect(segments[1].rect == CGRect(x: 468, y: 228, width: 44, height: 32))
        let shape = NotchShape.visibleRect(presentation: .closed, anchor: notch, panelFrame: panel,
                                           badgeWidth: [BadgeSlot.nowPlaying, .timer].totalWidth)
        #expect(segments.last!.rect.maxX == shape.maxX, "the last segment ends where the shape does")
    }

    /// On a pill the segments fill the pill, centred.
    @Test func onAPillSegmentsFillThePill() {
        let slots: [BadgeSlot] = [.nowPlaying, .timer]
        let segments = NotchShape.badgeSegments(slots, anchor: pill, panelFrame: pillPanel)
        let shape = NotchShape.visibleRect(presentation: .closed, anchor: pill, panelFrame: pillPanel,
                                           badgeWidth: slots.totalWidth)
        #expect(segments.first!.rect.minX == shape.minX)
        #expect(segments.last!.rect.maxX == shape.maxX)
    }

    @Test func thePointerFindsItsSegment() {
        let segments = NotchShape.badgeSegments([.nowPlaying, .timer], anchor: notch, panelFrame: panel)
        #expect(NotchShape.segment(at: CGPoint(x: 430, y: 240), in: segments) == .nowPlaying)
        #expect(NotchShape.segment(at: CGPoint(x: 490, y: 240), in: segments) == .timer)
        #expect(NotchShape.segment(at: CGPoint(x: 300, y: 240), in: segments) == nil, "the housing is no segment")
        // Below the band -- the lyrics strip -- belongs to no segment.
        #expect(NotchShape.segment(at: CGPoint(x: 490, y: 220), in: segments) == nil)
    }

    /// "Keep clear of app menus" keeps clear for the widest the closed pill
    /// gets, which is now every segment at once.
    @Test func thePillsWidestIsEverySegmentAtOnce() {
        let widest: [BadgeSlot] = [.nowPlaying, .timer, .stopwatch, .downloads, .capture]
        #expect(NotchGeometry.pillClosedMaxWidth == widest.totalWidth)
    }

    // MARK: - When they do not all fit

    /// The room right of a notch is the panel's half, less half the notch:
    /// the window is that wide and no wider, so a segment past it would be
    /// cut off -- and clicks on it would land nowhere.
    @Test func theRoomIsHalfThePanelPastTheNotch() {
        #expect(NotchShape.badgeRoom(anchor: notch, panelFrame: panel) == CGFloat(620 - 179) / 2)
    }

    /// Too many for the room: the least important go first -- the stopwatch,
    /// then downloads, then music, then the timer -- and the privacy dot
    /// never, since it is the one thing the user cannot see another way.
    /// What stays keeps its order from the notch out.
    @Test func whatDoesNotFitGoesLeastImportantFirst() {
        let all: [BadgeSlot] = [.nowPlaying, .timer, .stopwatch, .downloads, .capture]
        #expect(all.fitting(all.totalWidth) == all)
        #expect(all.fitting(all.totalWidth - 1) == [.nowPlaying, .timer, .downloads, .capture])
        let withoutStopwatch: [BadgeSlot] = [.nowPlaying, .timer, .downloads, .capture]
        #expect(all.fitting(withoutStopwatch.totalWidth - 1) == [.nowPlaying, .timer, .capture])
        #expect(all.fitting(NotchGeometry.captureBadgeWidth) == [.capture])
        #expect(all.fitting(0) == [.capture], "the privacy dot is kept even with no room")
    }

    @Test func slotsForAnAnchorFitItsRoom() {
        let all = NotchShape.badgeSlots(
            countdown: running(), stopwatch: lapping(), nowPlaying: playing,
            capture: CaptureUse(microphone: true), downloads: downloads,
            fitting: NotchShape.badgeRoom(anchor: notch, panelFrame: panel), at: t0.addingTimeInterval(60)
        )
        #expect(all.totalWidth <= NotchShape.badgeRoom(anchor: notch, panelFrame: panel))
        #expect(all.contains(.capture))
    }
}
