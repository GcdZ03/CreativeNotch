import SwiftUI
import CreativeNotchCore

/// Play/pause, next and previous, for whatever holds the media session.
///
/// `onCommand` is injected rather than calling `MediaRemoteBridge`
/// directly. A real command changes playback on the machine running the
/// tests, so the suite must never send one — injecting the sink is what
/// lets the button-to-command mapping be proven without that.
///
/// There is no play/pause *state* here, and the icon does not change: this
/// module cannot read whether anything is playing, because that read is
/// code-signing gated. Hence one toggle button rather than separate play
/// and pause buttons — the app genuinely does not know which it would be.
struct MediaControlsView: View {

    /// In transport order, left to right, as they appear on every physical
    /// remote and media key row.
    static let buttons: [(command: MediaCommand, symbol: String, label: String)] = [
        (.previousTrack, "backward.fill", "Previous track"),
        (.togglePlayPause, "playpause.fill", "Play or pause"),
        (.nextTrack, "forward.fill", "Next track"),
    ]

    let onCommand: (MediaCommand) -> Void

    init(onCommand: @escaping (MediaCommand) -> Void) {
        self.onCommand = onCommand
    }

    var body: some View {
        HStack(spacing: 18) {
            ForEach(Self.buttons, id: \.command) { button in
                Button {
                    onCommand(button.command)
                } label: {
                    Image(systemName: button.symbol)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 28, height: 24)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(button.label)
            }
        }
        .padding(.top, 10)
    }
}
