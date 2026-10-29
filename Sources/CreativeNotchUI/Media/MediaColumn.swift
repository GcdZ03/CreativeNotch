import AppKit
import SwiftUI
import CreativeNotchCore

/// What is playing and the controls for it, as a column (spec §5.2).
///
/// Fixed width, present whenever media controls are on. With no track it
/// shows a placeholder tile and dimmed controls rather than collapsing, so
/// the pane beside it never reflows when a track starts — the reflow that
/// made the camera tab special-case the old media bar.
///
/// The glow behind the cover is the artwork's average colour, computed once
/// per artwork change in `.task(id:)`. Nothing here animates.
struct MediaColumn: View {
    /// `PanelLayout.mediaColumnWidth`, grown with the text size. Handed in
    /// rather than read from the constant, so the column and the pane beside
    /// it are split by the one function that splits the panel.
    var width: CGFloat = PanelLayout.mediaColumnWidth
    let snapshot: TrackSnapshot?
    let artwork: Data?
    let showsControls: Bool
    /// Ties the cover to the badge's and the peek's, so it slides in
    /// from wherever the notch was (spec 2026-10-15).
    var coverNamespace: Namespace.ID? = nil
    /// The lyric line, or `nil` with the module off or no lyrics for the
    /// track (spec 2026-10-29). Shown paused too, unlike the strip: the open
    /// panel is somewhere a person went to look.
    var lyrics: LyricsText? = nil
    /// Seeks from the progress bar; `nil` leaves it display-only.
    var onSeek: ((TimeInterval) -> Void)? = nil
    let onCommand: (MediaCommand) -> Void

    @State private var tint: Color?
    @Environment(\.notchTextScale) private var textScale

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            cover

            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot?.title ?? String(localized: "Nothing playing", bundle: .creativeNotch))
                    .notchFont(14, weight: .semibold, design: .rounded)
                    .foregroundStyle(.ink(snapshot == nil ? 0.5 : 0.95))
                    .lineLimit(1)
                    .truncationMode(.tail)
                // The lyric line takes the artist's place while there is
                // one (spec 2026-10-29): the column has no room for a third
                // line at any text size.
                if snapshot != nil, let lyrics {
                    LyricsColumnView(text: lyrics)
                } else if let snapshot, !snapshot.artist.isEmpty {
                    Text(snapshot.artist)
                        .notchFont(12, design: .rounded)
                        .foregroundStyle(.ink(0.55))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            // The same bar the music peek shows (2026-10-18). Before this the
            // panel never showed where playback was, and with open on hover
            // the peek — its only home — could be skipped entirely.
            if let snapshot, let position = snapshot.position {
                PlaybackProgressView(position: position, isPlaying: snapshot.isPlaying, onSeek: onSeek)
            }

            if showsControls {
                MediaControlsView(isPlaying: Self.controlsPlayState(for: snapshot), onCommand: onCommand)
                    .opacity(snapshot == nil ? 0.6 : 1)
            }

            Spacer(minLength: 0)
        }
        .padding(.top, 18)
        .padding(.leading, 18)
        .padding(.trailing, 16)
        .padding(.bottom, 14)
        .frame(width: width, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(alignment: .topLeading) {
            if let tint {
                Circle()
                    .fill(tint.opacity(0.35))
                    .frame(width: NotchType.length(170, scale: textScale),
                           height: NotchType.length(170, scale: textScale))
                    .blur(radius: 18)
                    .offset(x: -30, y: -20)
                    .allowsHitTesting(false)
            }
        }
        .clipped()
        .overlay(alignment: .trailing) {
            Rectangle().fill(.hairline(0.08)).frame(width: 1)
        }
        .task(id: artwork) {
            tint = artwork.flatMap(ArtworkTint.color(for:))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(snapshot.map(NowPlayingLabel.text(for:)) ?? String(localized: "Nothing playing", bundle: .creativeNotch))
    }

    /// The play state the transport toggle shows, or `nil` with no track.
    static func controlsPlayState(for snapshot: TrackSnapshot?) -> Bool? {
        snapshot?.isPlaying
    }

    /// A 72pt cover -- grown with the text, so the column keeps its
    /// proportions -- with the hairline ring `NowPlayingView` established:
    /// album art is often dark at the edges and dissolves into the panel
    /// without it. With no artwork, a note glyph rather than a blank tile.
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
                        .notchFont(22, weight: .medium)
                        .foregroundStyle(.ink(0.5))
                }
            }
        }
        .frame(width: NotchType.length(72, scale: textScale), height: NotchType.length(72, scale: textScale))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.hairline(0.12), lineWidth: 1)
        }
        .nowPlayingCover(in: coverNamespace)
    }
}
