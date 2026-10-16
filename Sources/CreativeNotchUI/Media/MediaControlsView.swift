import SwiftUI
import CreativeNotchCore

/// Play/pause, next and previous, for whatever holds the media session.
///
/// `onCommand` is injected rather than calling `MediaRemoteBridge`
/// directly. A real command changes playback on the machine running the
/// tests, so the suite must never send one — injecting the sink is what
/// lets the button-to-command mapping be proven without that.
///
/// One toggle rather than separate play and pause buttons, because
/// MediaRemote takes one toggle command. Its icon follows the snapshot's
/// `isPlaying` when there is a track — the value the bridge *queries*
/// through the perl helper, which the code-signing gate does not block,
/// and the same one the music peek's button follows. With no track it
/// shows the combined glyph, since there is no state to show.
struct MediaControlsView: View {

    /// In transport order, left to right, as they appear on every physical
    /// remote and media key row.
    static let buttons: [(command: MediaCommand, symbol: String, label: String)] = [
        (.previousTrack, "backward.fill", "Previous track"),
        (.togglePlayPause, "playpause.fill", "Play or pause"),
        (.nextTrack, "forward.fill", "Next track"),
    ]

    let isPlaying: Bool?
    let onCommand: (MediaCommand) -> Void

    init(isPlaying: Bool? = nil, onCommand: @escaping (MediaCommand) -> Void) {
        self.isPlaying = isPlaying
        self.onCommand = onCommand
    }

    /// What the toggle shows: what pressing it will do.
    static func toggle(isPlaying: Bool?) -> (symbol: String, label: String) {
        switch isPlaying {
        case true?:  return ("pause.fill", "Pause")
        case false?: return ("play.fill", "Play")
        case nil:    return ("playpause.fill", "Play or pause")
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Self.buttons, id: \.command) { button in
                let isToggle = button.command == .togglePlayPause
                let symbol = isToggle ? Self.toggle(isPlaying: isPlaying).symbol : button.symbol
                let label = isToggle ? Self.toggle(isPlaying: isPlaying).label : button.label
                Button {
                    onCommand(button.command)
                } label: {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: isToggle ? 40 : 32, height: 28)
                        .background {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(.white.opacity(isToggle ? 0.16 : 0.08))
                        }
                        .contentShape(.rect)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label)
            }
        }
    }
}
