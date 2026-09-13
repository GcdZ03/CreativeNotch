import AppKit
import Foundation
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// The badge, driven through the delegate rather than through
/// `NotchShape.badgeSlot` directly.
///
/// **That distinction is the whole point of this file.** The Core function
/// takes `isRecording` and `capture` as defaulted parameters, so a caller that
/// simply never passes them compiles, and every test that calls the function
/// directly still passes. Both call sites did exactly that, which meant the
/// camera's recording badge -- the thing that makes its activity-gate
/// exemption honest -- never appeared at all.
///
/// Same shape as the `PanelTabBar` bug: the rule was right and nothing used it.
@MainActor
struct CaptureBadgeTests {

    private func makeDelegate() -> AppDelegate {
        let delegate = AppDelegate()
        delegate.preferencesDefaults = TestDefaults.isolated("capture-badge")
        delegate.growthDelay = .zero
        delegate.shelfDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureBadge-\(UUID().uuidString)")
        delegate.playChime = {}
        delegate.install(metrics: NotchedDelegate.metrics)
        // The indicator would otherwise read the developer's real
        // microphone and camera, so the suite would pass or fail
        // depending on whether they happened to be on a call.
        delegate.capture?.observer.readCurrentUse = { .none }
        return delegate
    }

    // MARK: - The capture indicator reaches the notch

    @Test func nothingCapturingTakesNoBadgeSlot() {
        let delegate = makeDelegate()
        #expect(delegate.currentBadgeWidth == 0)
    }

    @Test func aMicrophoneInUseWidensTheClosedNotch() {
        let delegate = makeDelegate()
        delegate.state.captureUse = CaptureUse(microphone: true)

        #expect(delegate.currentBadgeWidth == NotchGeometry.captureBadgeWidth)
    }

    @Test func aCameraInUseWidensTheClosedNotch() {
        let delegate = makeDelegate()
        delegate.state.captureUse = CaptureUse(camera: true)

        #expect(delegate.currentBadgeWidth == NotchGeometry.captureBadgeWidth)
    }

    /// Both at once is the same width. A badge that grew when the second
    /// device started would resize the closed notch mid-call.
    @Test func bothDevicesTakeTheSameWidthAsOne() {
        let delegate = makeDelegate()
        delegate.state.captureUse = CaptureUse(microphone: true, camera: true)

        #expect(delegate.currentBadgeWidth == NotchGeometry.captureBadgeWidth)
    }

    // MARK: - The camera's own recording badge

    /// **This is the assertion that was missing**, and its absence meant the
    /// red dot never appeared. The camera module's exemption from the activity
    /// gate is defensible only because a recording that outlives the panel is
    /// visible -- and it was not.
    @Test func aRecordingClipWidensTheClosedNotch() {
        let delegate = makeDelegate()
        delegate.state.isRecordingClip = true

        #expect(delegate.currentBadgeWidth == NotchGeometry.recordingBadgeWidth)
    }

    // MARK: - Priority, through the delegate

    /// Our own recording outranks somebody else's capture: it is the more
    /// specific claim about the same fact.
    @Test func ourOwnRecordingOutranksSomebodyElsesCapture() {
        let delegate = makeDelegate()
        delegate.state.captureUse = CaptureUse(camera: true)
        delegate.state.isRecordingClip = true

        #expect(delegate.currentBadgeWidth == NotchGeometry.recordingBadgeWidth)
    }

    /// **A capture outranks a running timer and a playing track**, because it
    /// is the one thing in the list the user cannot find out any other way.
    @Test func aCaptureOutranksTheTimerAndTheTrack() {
        let delegate = makeDelegate()
        delegate.state.countdown = Countdown(duration: 600, startingAt: Date())
        delegate.state.nowPlaying = TrackSnapshot(title: "T", artist: "A", isPlaying: true)
        #expect(delegate.currentBadgeWidth == NotchGeometry.timerBadgeWidth)

        delegate.state.captureUse = CaptureUse(microphone: true)

        #expect(delegate.currentBadgeWidth == NotchGeometry.captureBadgeWidth)
    }

    /// And it yields when the capture stops, rather than sticking.
    @Test func theSlotGoesBackWhenCapturingEnds() {
        let delegate = makeDelegate()
        delegate.state.nowPlaying = TrackSnapshot(title: "T", artist: "A", isPlaying: true)
        delegate.state.captureUse = CaptureUse(camera: true)
        #expect(delegate.currentBadgeWidth == NotchGeometry.captureBadgeWidth)

        delegate.state.captureUse = .none

        #expect(delegate.currentBadgeWidth == NotchGeometry.nowPlayingBadgeWidth)
    }
}
