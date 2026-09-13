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
    let snapshot: TrackSnapshot?
    let artwork: Data?
    let showsControls: Bool
    let onCommand: (MediaCommand) -> Void

    @State private var tint: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            cover

            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot?.title ?? "Nothing playing")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(snapshot == nil ? 0.5 : 0.95))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let snapshot, !snapshot.artist.isEmpty {
                    Text(snapshot.artist)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            if showsControls {
                MediaControlsView(onCommand: onCommand)
                    .opacity(snapshot == nil ? 0.6 : 1)
            }

            Spacer(minLength: 0)
        }
        .padding(.top, 18)
        .padding(.leading, 18)
        .padding(.trailing, 16)
        .padding(.bottom, 14)
        .frame(width: PanelLayout.mediaColumnWidth, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(alignment: .topLeading) {
            if let tint {
                Circle()
                    .fill(tint.opacity(0.35))
                    .frame(width: 170, height: 170)
                    .blur(radius: 18)
                    .offset(x: -30, y: -20)
                    .allowsHitTesting(false)
            }
        }
        .clipped()
        .overlay(alignment: .trailing) {
            Rectangle().fill(.white.opacity(0.08)).frame(width: 1)
        }
        .task(id: artwork) {
            tint = artwork.flatMap(ArtworkTint.color(for:))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(snapshot.map(NowPlayingLabel.text(for:)) ?? "Nothing playing")
    }

    /// A 72pt cover with the hairline ring `NowPlayingView` established:
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
                    Rectangle().fill(.white.opacity(0.08))
                    Image(systemName: "music.note")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .frame(width: 72, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }
    }
}
