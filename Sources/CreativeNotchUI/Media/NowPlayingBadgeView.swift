import AppKit
import SwiftUI
import CreativeNotchCore

/// The ambient now-playing badge: a small tab on the trailing side of the
/// closed notch, in the spirit of a Live Activity.
///
/// It answers one question at a glance — is something playing — and it is
/// **static**. No pulse, no equalizer, no `TimelineView`: it is on screen
/// for as long as music plays, and this app exists precisely to not redraw
/// continuously for that long. Its only redraws are the ones the artwork
/// or the playing state cause.
///
/// Sized by `NotchGeometry.nowPlayingBadgeWidth`, the same constant that
/// grows the shape it sits in, so the tile can never outgrow the region
/// drawn for it.
struct NowPlayingBadgeView: View {
    var artwork: Data?

    /// Leaves 6pt either side inside the 34pt badge.
    private let tile: CGFloat = 22

    var body: some View {
        content
            .frame(width: tile, height: tile)
            .frame(width: NotchGeometry.nowPlayingBadgeWidth)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Now playing")
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
