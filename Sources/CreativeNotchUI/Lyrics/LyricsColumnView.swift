import SwiftUI
import CreativeNotchCore

/// The panel's lyric line: the music column's second line, under the title,
/// in place of the artist while there are lyrics (spec 2026-10-29).
///
/// In place of rather than under: the column already filled the panel's
/// body to within a few points at every text size, and a lyrics row below
/// the progress bar pushed the transport controls off the bottom. The artist
/// is still in the peek and the strip's hover. Set in the panel's type
/// scale, like the rest of the column; the strip and the peek are fixed
/// sizes (`LyricLineView`).
struct LyricsColumnView: View {
    let text: LyricsText

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "quote.bubble")
                .notchFont(10, weight: .semibold)
                .foregroundStyle(.ink(0.45))
            Group {
                if let current = text.current, !current.isEmpty {
                    Text(current)
                        .notchFont(12, weight: .medium, design: .rounded)
                        .foregroundStyle(.ink(0.8))
                } else {
                    Image(systemName: "music.note")
                        .notchFont(10, weight: .semibold)
                        .foregroundStyle(.ink(0.45))
                }
            }
            .lineLimit(1)
            .truncationMode(.tail)
        }
        // Swapped, not faded, like the strip (`LyricLineView`).
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LyricLineView.accessibilityText(for: text.current))
    }
}
