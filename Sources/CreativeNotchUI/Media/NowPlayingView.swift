import AppKit
import SwiftUI
import CreativeNotchCore

/// Pure formatting for the now-playing header.
///
/// Pulled out of `NowPlayingView` so it is testable without rendering
/// anything — the same split `HUDView` and `MediaControlsView` do not
/// need because they have no string to compose.
enum NowPlayingLabel {
    /// `"title — artist"`, or just `title` when there is no artist to
    /// join. Some tracks genuinely have no artist — podcasts, voice
    /// memos — and a dangling separator on those would look broken.
    static func text(for snapshot: TrackSnapshot) -> String {
        guard !snapshot.artist.isEmpty else { return snapshot.title }
        return "\(snapshot.title) — \(snapshot.artist)"
    }
}

/// The now-playing header: artwork beside title and artist, single line,
/// truncating tail.
///
/// Shown only while there is a snapshot to describe — `NotchRootView`
/// gates its presence on `app.nowPlaying`, the same way it gates
/// `MediaControlsView` on `app.showsMediaControls`, so this view itself
/// never has to render an empty state.
struct NowPlayingView: View {
    let snapshot: TrackSnapshot
    let artwork: Data?

    var body: some View {
        HStack(spacing: 8) {
            artworkView
            Text(NowPlayingLabel.text(for: snapshot))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.top, 10)
        .padding(.horizontal, 14)
    }

    /// Falls back to a blank tile rather than hiding, so the label does
    /// not jump sideways the moment artwork arrives a beat later than the
    /// title — the exact flap `MediaArtworkCache` exists to hide.
    @ViewBuilder
    private var artworkView: some View {
        if let artwork, let image = NSImage(data: artwork) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(.white.opacity(0.12))
                .frame(width: 28, height: 28)
        }
    }
}
