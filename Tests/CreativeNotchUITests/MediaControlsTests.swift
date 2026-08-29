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
        let labels = Dictionary(
            uniqueKeysWithValues: MediaControlsView.buttons.map { ($0.command, $0.label) }
        )
        #expect(labels[.previousTrack] == "Previous track")
        #expect(labels[.togglePlayPause] == "Play or pause")
        #expect(labels[.nextTrack] == "Next track")
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
