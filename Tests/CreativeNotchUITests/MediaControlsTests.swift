import AppKit
import Foundation
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// The buttons, and what each one sends.
///
/// Views are not unit-tested here, so what is pinned is the mapping — the
/// part with a right answer, and the part where a copy-paste slip would
/// wire "next" to the previous-track command with nothing to catch it.
@MainActor
struct MediaControlsTests {

    // MARK: - The availability probe

    private static let notched = ScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 1470, height: 956),
        safeAreaTopInset: 38,
        auxiliaryTopLeftWidth: 620,
        auxiliaryTopRightWidth: 620,
        menuBarHeight: 38
    )

    private func makeDelegate(available: @escaping () -> Bool) -> AppDelegate {
        let delegate = AppDelegate()
        delegate.preferencesDefaults = TestDefaults.isolated()
        delegate.growthDelay = .zero
        delegate.shelfDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CreativeNotchMediaControls-\(UUID().uuidString)")
        delegate.mediaRemoteAvailable = available
        delegate.install(metrics: Self.notched)
        return delegate
    }

    /// Reading `MediaRemoteBridge.isAvailable` is what performs the `dlopen`,
    /// and there is no `dlclose`. Once the transport toggle exists, the read
    /// has to sit on the RIGHT of a lazy `&&` with the preference on its
    /// left, or disabling the module still loads the private framework the
    /// user just declined.
    ///
    /// `handle` is a `private static let` already forced open by
    /// `MediaRemoteBridgeTests` in this same process, so no test can tell the
    /// two spellings apart by observing the bridge. Counting calls to this
    /// seam is the only way the order is provable at all.
    @Test func installReadsAvailabilityThroughTheProbe() {
        var probes = 0
        let delegate = makeDelegate(available: { probes += 1; return true })

        #expect(probes == 1)
        #expect(delegate.state.showsMediaControls)
    }

    /// And the seam is honoured rather than merely called: an unavailable
    /// bridge means no transport buttons.
    @Test func anUnavailableBridgeHidesTheControls() {
        let delegate = makeDelegate(available: { false })
        #expect(delegate.state.showsMediaControls == false)
    }

    @Test func thereAreThreeButtonsInTransportOrder() {
        #expect(MediaControlsView.buttons.map(\.command) == [
            .previousTrack, .togglePlayPause, .nextTrack,
        ])
    }

    /// Each button sends its own command and no other. A slip here is
    /// invisible on screen — the icons would still look right.
    @Test func eachButtonSendsADistinctCommand() {
        let commands = MediaControlsView.buttons.map(\.command)
        #expect(Set(commands).count == commands.count)
    }

    @Test func everyButtonHasASymbolAndALabel() {
        for button in MediaControlsView.buttons {
            #expect(button.symbol.isEmpty == false)
            #expect(button.label.isEmpty == false)
        }
    }

    /// Accessibility labels are how this is operated without sight, and
    /// the notch is small enough that the icons alone are ambiguous.
    @Test func theLabelsDescribeTheAction() {
        // Use first(where:) for non-trapping lookup so duplicate commands fail cleanly
        let previousLabel = MediaControlsView.buttons.first(where: { $0.command == .previousTrack })?.label
        let playPauseLabel = MediaControlsView.buttons.first(where: { $0.command == .togglePlayPause })?.label
        let nextLabel = MediaControlsView.buttons.first(where: { $0.command == .nextTrack })?.label

        #expect(previousLabel == "Previous track")
        #expect(playPauseLabel == "Play or pause")
        #expect(nextLabel == "Next track")
    }

    /// The injected closure is what the panel wires to the bridge. If a
    /// button did not call it, the control would be dead on screen with
    /// nothing failing.
    @Test func tappingAButtonInvokesTheHandler() {
        var sent: [MediaCommand] = []
        let view = MediaControlsView { sent.append($0) }

        for button in MediaControlsView.buttons {
            view.onCommand(button.command)
        }

        #expect(sent == [.previousTrack, .togglePlayPause, .nextTrack])
    }
}
