import Foundation
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// What VoiceOver hears for a running timer, in the panel and in the ear.
///
/// The words are `TimerSpokenTextTests`'s; these pin that each view feeds
/// them the right inputs — the same `now` the digits and the bar are drawn
/// from, and the countdown's own paused state — since a swapped argument
/// compiles and renders identically.
@MainActor
struct TimerAccessibilityTests {

    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    /// The countdown and the bar, as one value. The bar used to be hidden
    /// with nothing standing in for it; its progress is now in the sentence.
    @Test func thePanelCountdownSaysTimeLeftAndProgress() throws {
        let c = try #require(Countdown(duration: 600, startingAt: t0))
        let at = t0.addingTimeInterval(150)
        #expect(TimerTabView.accessibilityValue(c, at: at) == "8 minutes remaining, 25% done")
    }

    @Test func aPausedCountdownSaysSo() throws {
        let c = try #require(Countdown(duration: 600, startingAt: t0)).paused(at: t0.addingTimeInterval(570))
        // Paused, so a later `now` changes nothing.
        #expect(TimerTabView.accessibilityValue(c, at: t0.addingTimeInterval(9_000))
                == "Paused, 30 seconds remaining, 95% done")
    }

    /// The ear badge speaks words, not "25 m".
    @Test func theBadgeSpeaksTheRemainingTimeInWords() {
        #expect(TimerBadgeView(text: "25m", isPaused: false, remaining: 1500).accessibilityText
                == "25 minutes remaining")
        #expect(TimerBadgeView(text: "0:42", isPaused: true, remaining: 42).accessibilityText
                == "Timer paused, 42 seconds remaining")
    }

    @Test func theDonePeekSpeaksTheCompletion() {
        let peek = TimerDonePeekView(completion: TimerCompletion(duration: 1500, lateness: 300))
        #expect(peek.accessibilityText == "25-minute timer finished 5 minutes ago")
    }
}
