import Foundation
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// What VoiceOver reads for each badge and peek on the closed notch.
///
/// Labels are not reachable from a unit test once SwiftUI has rendered
/// them, so each view exposes the string it sets — the pattern
/// `ShelfView.tileAccessibilityLabel` set — and these pin the words. The
/// timer's badge and done peek are in `TimerAccessibilityTests`.
@MainActor
struct BadgeAccessibilityTests {

    /// The cover is a picture; what it is a picture of is the track.
    @Test func theNowPlayingBadgeNamesTheTrack() {
        let track = TrackSnapshot(title: "Blue in Green", artist: "Miles Davis", isPlaying: true)
        #expect(NowPlayingBadgeView(track: track).accessibilityText
                == "Now playing: Blue in Green by Miles Davis")
    }

    @Test func theNowPlayingBadgeWithoutATrackStillSaysWhatItIs() {
        #expect(NowPlayingBadgeView().accessibilityText == "Now playing")
    }

    /// One element for both glyphs, so a call with both devices on is one
    /// sentence rather than two stops a VoiceOver user may not reach both of.
    @Test func theCaptureBadgeSaysWhichDevicesAreInUse() {
        #expect(CaptureBadgeView.accessibilityText(for: CaptureUse(microphone: true))
                == "Microphone in use")
        #expect(CaptureBadgeView.accessibilityText(for: CaptureUse(camera: true))
                == "Camera in use")
        #expect(CaptureBadgeView.accessibilityText(for: CaptureUse(microphone: true, camera: true))
                == "Microphone and camera in use")
    }

    /// The same words the announcement uses, so landing on the peek and
    /// hearing it appear say the same thing.
    @Test func thePowerPeekSaysTheEventAndLevel() {
        #expect(PowerPeekView(event: .unplugged(level: 66)).accessibilityText == "On Battery, 66%")
        #expect(PowerPeekView(event: .lowPowerMode(enabled: false)).accessibilityText
                == "Low Power Mode Off")
        #expect(PowerPeekView(event: .pluggedIn(level: 80)).accessibilityText
                == PeekAnnouncement.text(for: .power(.pluggedIn(level: 80))))
    }

    /// "Recording" alone, beside a microphone badge, does not say what is.
    @Test func theRecordingDotSaysTheCameraIsRecording() {
        #expect(RecordingBadgeView.accessibilityText == "Camera recording")
    }
}
