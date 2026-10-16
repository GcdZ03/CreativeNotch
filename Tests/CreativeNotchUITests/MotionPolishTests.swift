import AppKit
import SwiftUI
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// Reduce Motion, haptics, AirDrop from the shelf, and rolling digits
/// (spec 2026-10-17).
@MainActor
struct MotionPolishTests {

    private static let track = TrackSnapshot(title: "Song", artist: "Band", isPlaying: true)
    private static let closedDrawn = CGRect(x: 195, y: 0, width: 230, height: 38)

    // MARK: - Reduce Motion

    /// With Reduce Motion on, every state change is the same short ease,
    /// whichever way it moves: no bounce, no snap.
    @Test func reduceMotionReplacesBothSpringsWithOneEase() {
        #expect(NotchMotion.animation(growing: true, reduceMotion: true) == NotchMotion.reduced)
        #expect(NotchMotion.animation(growing: false, reduceMotion: true) == NotchMotion.reduced)
        #expect(NotchMotion.animation(growing: true, reduceMotion: false) == NotchMotion.open)
        #expect(NotchMotion.animation(growing: false, reduceMotion: false) == NotchMotion.close)
    }

    @Test func reduceMotionDropsTheHoverGrowth() {
        let r = NotchRootView.hoverInflated(
            Self.closedDrawn, isHovering: true, state: .closed, reduceMotion: true
        )
        #expect(r == Self.closedDrawn)
    }

    /// No shared namespace means the cover cross-fades between states
    /// instead of sliding across the screen.
    @Test func reduceMotionStopsTheCoverSliding() {
        #expect(!NotchMotion.slidesCover(reduceMotion: true))
        #expect(NotchMotion.slidesCover(reduceMotion: false))
    }

    @Test func rollingDigitsBecomeAFadeUnderReduceMotion() {
        #expect(RollingDigits<Int>.transition(countsDown: true, reduceMotion: true) == .opacity)
        #expect(RollingDigits<Int>.transition(countsDown: true, reduceMotion: false)
                == .numericText(countsDown: true))
    }

    // MARK: - Haptics

    private func delegateRecordingHaptics() -> (AppDelegate, () -> Int) {
        let delegate = NotchedDelegate.make()
        var count = 0
        delegate.performHaptic = { count += 1 }
        return (delegate, { count })
    }

    /// One tap as the panel opens — the deliberate action — and on nothing
    /// else.
    @Test func openingThePanelTapsOnce() {
        let (delegate, taps) = delegateRecordingHaptics()
        delegate.state.transition(to: .open(.shelf))
        #expect(taps() == 1)
    }

    /// Switching tabs is not opening.
    @Test func switchingTabsDoesNotTap() {
        let (delegate, taps) = delegateRecordingHaptics()
        delegate.state.transition(to: .open(.shelf))
        delegate.state.transition(to: .open(.clipboard))
        #expect(taps() == 1)
    }

    /// A peek fires on hover, unasked; tapping the finger for it would be
    /// noise. Closing is not tapped either.
    @Test func peekingAndClosingDoNotTap() {
        let (delegate, taps) = delegateRecordingHaptics()
        delegate.state.transition(to: .peek(.nowPlaying(Self.track)))
        delegate.state.transition(to: .closed)
        #expect(taps() == 0)
        delegate.state.transition(to: .open(.shelf))
        delegate.state.transition(to: .closed)
        delegate.state.transition(to: .open(.shelf))
        #expect(taps() == 2)
    }

    // MARK: - AirDrop

    private final class FakeSharing: SharingPerforming {
        var available = true
        var sent: [[URL]] = []
        func canPerform(withItems items: [Any]?) -> Bool { available }
        func perform(withItems items: [Any]) { sent.append(items.compactMap { $0 as? URL }) }
    }

    private func tempFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("airdrop-\(UUID()).txt")
        try Data("x".utf8).write(to: url)
        return url
    }

    @Test func airDropSendsTheFilesItIsHanded() throws {
        let file = try tempFile()
        let service = FakeSharing()
        #expect(ShelfAirDrop.send([file], via: service))
        #expect(service.sent == [[file]])
    }

    /// A shelf item whose file has gone is skipped rather than handed to
    /// AirDrop, which would offer to send nothing.
    @Test func missingFilesAreLeftOut() throws {
        let file = try tempFile()
        let gone = FileManager.default.temporaryDirectory.appendingPathComponent("gone-\(UUID())")
        let service = FakeSharing()
        #expect(ShelfAirDrop.send([gone, file], via: service))
        #expect(service.sent == [[file]])
        #expect(!ShelfAirDrop.send([gone], via: service))
    }

    @Test func nothingIsSentWhenAirDropIsUnavailable() throws {
        let service = FakeSharing()
        service.available = false
        #expect(!ShelfAirDrop.send([try tempFile()], via: service))
        #expect(service.sent.isEmpty)
    }

    /// The view gets a verb through `AppState`, like every other shelf verb.
    @Test func theDelegateWiresTheAirDropVerb() {
        let delegate = NotchedDelegate.make()
        #expect(delegate.state.onAirDropShelfItems != nil)
    }
}
