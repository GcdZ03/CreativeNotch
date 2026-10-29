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
    /// Whether the line under the notch is tucked away (2026-10-29).
    var tuckedAway = false
    /// The glyph is a button that tucks it away or brings it back -- the
    /// way for anyone who would rather not swipe, and the only one when
    /// open on hover has opened the panel before a swipe could start.
    var onToggle: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 5) {
            toggle
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
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(LyricLineView.accessibilityText(for: text.current))
        }
        // Swapped, not faded, like the strip (`LyricLineView`).
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func toggleLabel(tuckedAway: Bool) -> String {
        tuckedAway
            ? String(localized: "Show lyrics under the notch", bundle: .creativeNotch)
            : String(localized: "Hide lyrics under the notch", bundle: .creativeNotch)
    }

    /// Filled while the line shows under the notch, an outline while it is
    /// tucked away.
    @ViewBuilder
    private var toggle: some View {
        let glyph = Image(systemName: tuckedAway ? "quote.bubble" : "quote.bubble.fill")
            .notchFont(10, weight: .semibold)
            .foregroundStyle(.ink(tuckedAway ? 0.35 : 0.6))
        if let onToggle {
            Button(action: onToggle) { glyph.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .help(Self.toggleLabel(tuckedAway: tuckedAway))
                .accessibilityLabel(Self.toggleLabel(tuckedAway: tuckedAway))
        } else {
            glyph.accessibilityHidden(true)
        }
    }
}
