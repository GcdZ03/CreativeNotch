import AppKit
import SwiftUI
import CreativeNotchCore

/// Pure formatting for the one-line case.
///
/// Pulled out so it is testable without rendering anything — a split
/// `MediaControlsView` does not need, because it has no string to compose.
///
/// The accessibility label for the peek and the panel, which both set
/// title and artist on separate lines but read as one phrase.
enum NowPlayingLabel {
    /// `"title — artist"`, or just `title` when there is no artist to
    /// join. Some tracks genuinely have no artist — podcasts, voice
    /// memos — and a dangling separator on those would look broken.
    static func text(for snapshot: TrackSnapshot) -> String {
        guard !snapshot.artist.isEmpty else { return snapshot.title }
        return String(localized: "\(snapshot.title) — \(snapshot.artist)", bundle: .creativeNotch, comment: "Track title — artist")
    }
}

/// The music peek: what hovering the notch shows while there is a track
/// (spec 2026-10-15).
///
/// It grows **down** from the notch into a mini player. The top band keeps
/// the notch's own height and holds the moving equalizer in its trailing
/// ear; the body below holds the cover, title over artist, and play/pause.
///
/// On a Mac with a physical notch, the middle of that band is the camera
/// housing — anything drawn there is invisible. This project learned that
/// the expensive way, with a centred slab that put 72% of itself behind the
/// notch, so the bars start just past `notchGap` and never inside it. The
/// body hangs below the housing and has nothing to avoid.
///
/// `notchGap` is zero on a notchless Mac and on external displays, where
/// the bars simply sit at the band's trailing edge.
struct NowPlayingPeekView: View {
    let track: TrackSnapshot
    var artwork: Data?
    var notchGap: CGFloat = 0
    var bandHeight: CGFloat = 32
    /// `AppState.nowPlayingBarTint`, sampled once per artwork change.
    var barTint: Color? = nil
    /// Wide artwork gets a wider tile, as in the closed notch.
    var artworkAspect: CGFloat? = nil
    var coverNamespace: Namespace.ID? = nil
    var onCommand: (MediaCommand) -> Void = { _ in }
    /// Seeks from the progress bar; `nil` leaves it display-only.
    var onSeek: ((TimeInterval) -> Void)? = nil

    private let coverSize: CGFloat = 48

    var body: some View {
        VStack(spacing: 0) {
            band
                .frame(height: bandHeight)
            // 6pt rather than 10 since the bar became seekable: its touch
            // target is 14pt tall, and 12 + 48 + 6 + 30 fits the 100pt body.
            VStack(spacing: 6) {
                player
                if let position = track.position {
                    PlaybackProgressView(position: position, isPlaying: track.isPlaying, onSeek: onSeek)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, track.position == nil ? 0 : 12)
            // The body's height is fixed (`mediaPeekBodyHeight`), so a
            // track without a position centres its row in the same space
            // rather than leaving a gap where the bar would be.
            .frame(maxHeight: .infinity, alignment: track.position == nil ? .center : .top)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(NowPlayingLabel.text(for: track))
    }

    /// The notch's own band: empty except for the bars, which sit in the
    /// trailing ear just clear of the housing.
    @ViewBuilder
    private var band: some View {
        let bars = EqualizerBarsView(isPlaying: track.isPlaying, animates: true, color: barTint ?? .white)
        if notchGap > 0 {
            HStack(spacing: 0) {
                Color.clear
                Color.clear.frame(width: notchGap)
                bars
                    .padding(.leading, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            bars
                .padding(.trailing, 16)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var player: some View {
        HStack(spacing: 12) {
            cover
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.ink(0.95))
                    .contentTransition(.opacity)
                // Dropped rather than reserved, as in the panel, so a
                // track with no artist sits level with the cover.
                if !track.artist.isEmpty {
                    Text(track.artist)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.ink(0.55))
                        .contentTransition(.opacity)
                }
            }
            .lineLimit(1)
            .truncationMode(.tail)
            // Scoped to the text, so a new track cross-fades its title
            // without animating anything that sizes the shape.
            .animation(.smooth(duration: 0.35), value: track)
            Spacer(minLength: 8)
            playPause
        }
    }

    /// The icon follows the snapshot's `isPlaying`, which the bridge
    /// queries rather than infers — the same value the badge relies on.
    private var playPause: some View {
        Button {
            onCommand(.togglePlayPause)
        } label: {
            Image(systemName: track.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Circle().fill(.hairline(0.14)))
                .contentShape(Circle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(track.isPlaying ? String(localized: "Pause", bundle: .creativeNotch) : String(localized: "Play", bundle: .creativeNotch))
    }

    /// A note glyph rather than nothing when there is no artwork.
    ///
    /// The old one-line peek omitted its 16pt cover in that case, because
    /// a blank square in a glance read worse than none. At 48pt the cover
    /// is the layout's anchor and the text is set against it, so it holds
    /// its place, as the badge's and the panel's do.
    @ViewBuilder
    private var cover: some View {
        Group {
            if let artwork, let image = NSImage(data: artwork) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Rectangle().fill(.hairline(0.08))
                    Image(systemName: "music.note")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.ink(0.5))
                }
            }
        }
        .frame(
            width: NotchGeometry.coverWidth(height: coverSize, aspect: artwork == nil ? nil : artworkAspect),
            height: coverSize
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.hairline(0.12), lineWidth: 1)
        }
        .nowPlayingCover(in: coverNamespace)
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
                    .foregroundStyle(.ink(0.95))
                    .lineLimit(1)
                    .truncationMode(.tail)

                // Dropped entirely rather than reserved, so a track with no
                // artist sits optically centred against the artwork instead
                // of hanging off its top edge.
                if !snapshot.artist.isEmpty {
                    Text(snapshot.artist)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.ink(0.5))
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
                Rectangle().fill(.hairline(0.10))
            }
        }
        .frame(width: artworkSize, height: artworkSize)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(.hairline(0.12), lineWidth: 1)
        }
    }
}
