import AppKit
import SwiftUI
import CreativeNotchCore

/// The ambient now-playing cover: a small tile in the closed notch's trailing
/// ear, just past the housing, with `EqualizerBarsView` beside it — in the
/// spirit of a Live Activity (2026-10-17). Wide artwork, a video thumbnail,
/// gets a wider tile (`NotchGeometry.coverWidth`).
///
/// It answers one question at a glance — is something playing — and it is
/// **static**. No pulse and no `TimelineView`, and the bars beside it stand
/// still too: it is on screen for as long as music plays, and this app
/// exists precisely to not redraw continuously for that long. Its only
/// redraws are the ones the artwork or the playing state cause.
///
/// The cover is the same one the music peek and the panel show, tied by
/// `nowPlayingCover(in:)`, so it slides into them rather than popping.
///
/// Sized by `NotchGeometry.nowPlayingBadgeWidth`, the same constant that
/// grows the shape it sits in, so the tile can never outgrow the region
/// drawn for it.
struct NowPlayingBadgeView: View {
    var artwork: Data?
    /// The artwork's width over its height, from `AppState`.
    var aspect: CGFloat? = nil
    var coverNamespace: Namespace.ID? = nil
    /// The track the cover belongs to, for VoiceOver only. The badge draws
    /// nothing from it — its redraws stay the artwork's and nothing else's —
    /// but "Now playing" alone tells a VoiceOver user less than the cover
    /// tells everyone else.
    var track: TrackSnapshot? = nil

    private let tile: CGFloat = 22

    /// The peek's own sentence (`PeekAnnouncement.nowPlaying`), or just
    /// "Now playing" before a title has arrived.
    var accessibilityText: String {
        track.map(PeekAnnouncement.nowPlaying) ?? "Now playing"
    }

    var body: some View {
        content
            .frame(width: NotchGeometry.coverWidth(height: tile, aspect: artwork == nil ? nil : aspect), height: tile)
            // After the frame, so a wide image filling a wide tile is cut
            // to the tile rather than to its own overflowing bounds.
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .nowPlayingCover(in: coverNamespace)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
    }

    /// A glyph, not a blank tile, when there is no artwork.
    ///
    /// `NowPlayingPeekView` omits its cover entirely in that case because
    /// a peek is transient. This is not: an empty grey square parked in
    /// the menu bar for the length of an album reads as a broken app,
    /// whereas a note glyph still says the one thing the badge is for.
    @ViewBuilder
    private var content: some View {
        if let artwork, let image = NSImage(data: artwork) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay {
                    // Album art is often dark at the edges; without this a
                    // black cover dissolves into the black notch.
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
                }
        } else {
            Image(systemName: "music.note")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
        }
    }
}
