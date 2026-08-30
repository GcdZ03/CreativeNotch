import AppKit
import SwiftUI
import CreativeNotchCore

/// Pure formatting for the one-line case.
///
/// Pulled out so it is testable without rendering anything — the same
/// split `HUDView` and `MediaControlsView` do not need, because they have
/// no string to compose.
///
/// Used by the **peek**, which has one line to work with. The open
/// panel's header has room for two and sets title and artist separately,
/// so it does not go through here. Two presentations of the same data,
/// each sized to the space it has.
enum NowPlayingLabel {
    /// `"title — artist"`, or just `title` when there is no artist to
    /// join. Some tracks genuinely have no artist — podcasts, voice
    /// memos — and a dangling separator on those would look broken.
    static func text(for snapshot: TrackSnapshot) -> String {
        guard !snapshot.artist.isEmpty else { return snapshot.title }
        return "\(snapshot.title) — \(snapshot.artist)"
    }
}

/// What the closed notch shows while music plays.
///
/// On a Mac with a physical notch, the middle of this band is the camera
/// housing — anything drawn there is invisible. `HUDView` learned this the
/// expensive way (a centred slab put 72% of its level bar behind the
/// notch), so this follows the same shape: content lives in the ears, and
/// the gap between them is left empty.
///
/// The split is not arbitrary. Title hugs the notch's left edge and artist
/// its right, so the pair reads as one line interrupted by the hardware
/// rather than as two unrelated labels. Title takes the left because that
/// is where reading starts and it is the thing you are actually checking.
///
/// `notchGap` is zero on a notchless Mac and on external displays, where
/// there is nothing to avoid and the single centred line is correct.
struct NowPlayingPeekView: View {
    let track: TrackSnapshot
    var notchGap: CGFloat = 0

    var body: some View {
        if notchGap > 0 {
            HStack(spacing: 0) {
                text(track.title, weight: .semibold, opacity: 0.95)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 12)

                Color.clear.frame(width: notchGap)

                text(track.artist, weight: .regular, opacity: 0.6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 12)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(NowPlayingLabel.text(for: track))
        } else {
            text(NowPlayingLabel.text(for: track), weight: .medium, opacity: 0.9)
                .padding(.horizontal, 14)
        }
    }

    private func text(_ string: String, weight: Font.Weight, opacity: Double) -> some View {
        Text(string)
            .font(.system(size: 12, weight: weight, design: .rounded))
            .foregroundStyle(.white.opacity(opacity))
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

/// The now-playing cluster: artwork, then title over artist.
///
/// Deliberately does NOT own its outer padding or the transport controls.
/// `NotchRootView` composes this and `MediaControlsView` into a single
/// full-width bar, because they are one object — the thing that is
/// playing, and the controls for it. Splitting them into separate rows is
/// what made the panel read as two unrelated designs stacked: a
/// left-aligned header above centred buttons, with the whole right half of
/// the row empty.
///
/// Shown only while there is a snapshot to describe — `NotchRootView`
/// gates its presence on `app.nowPlaying`, so this view never has to
/// render an empty state.
struct NowPlayingView: View {
    let snapshot: TrackSnapshot
    let artwork: Data?

    /// Big enough to read a cover at a glance, small enough that two lines
    /// of type sit level with it.
    private let artworkSize: CGFloat = 40

    var body: some View {
        HStack(spacing: 10) {
            artworkView

            VStack(alignment: .leading, spacing: 1) {
                Text(snapshot.title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(1)
                    .truncationMode(.tail)

                // Dropped entirely rather than reserved, so a track with no
                // artist sits optically centred against the artwork instead
                // of hanging off its top edge.
                if !snapshot.artist.isEmpty {
                    Text(snapshot.artist)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(NowPlayingLabel.text(for: snapshot))
    }

    /// Falls back to a blank tile rather than hiding, so the text does not
    /// jump sideways the moment artwork arrives a beat later than the
    /// title — the exact flap `MediaArtworkCache` exists to hide.
    ///
    /// The hairline is not decoration: album art is frequently dark at the
    /// edges, and without it a black cover dissolves into a black panel and
    /// the layout looks broken rather than minimal.
    @ViewBuilder
    private var artworkView: some View {
        Group {
            if let artwork, let image = NSImage(data: artwork) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.white.opacity(0.10))
            }
        }
        .frame(width: artworkSize, height: artworkSize)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }
    }
}
