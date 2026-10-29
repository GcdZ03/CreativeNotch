import SwiftUI
import CreativeNotchCore

/// One line of lyrics, as the strip under the closed notch and the music
/// peek's row draw it (spec 2026-10-29).
///
/// Redrawn only when the line changes -- the controller's one-shot, about
/// every four seconds -- with one cross-fade scoped to the text. Nothing
/// here loops or reads a clock. A break between lines, or the wait before
/// the first, shows a note glyph rather than nothing: a strip that emptied
/// on every break would read as the app losing its place.
struct LyricLineView: View {
    let line: String?
    var size: CGFloat = 12
    var opacity: Double = 0.9
    var alignment: Alignment = .center

    var body: some View {
        ZStack(alignment: alignment) {
            if let line, !line.isEmpty {
                Text(line)
                    .font(.system(size: size, weight: .semibold, design: .rounded))
                    .foregroundStyle(.ink(opacity))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .truncationMode(.tail)
                    .transition(.opacity)
                    .id(line)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: size - 2, weight: .semibold))
                    .foregroundStyle(.ink(opacity * 0.5))
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.3), value: line)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityText(for: line))
    }

    static func accessibilityText(for line: String?) -> String {
        guard let line, !line.isEmpty else {
            return String(localized: "Lyrics: instrumental", bundle: .creativeNotch)
        }
        return String(localized: "Lyrics: \(line)", bundle: .creativeNotch, comment: "The lyric line being sung")
    }
}

/// The strip under the closed notch: the current line, centred across the
/// notch and its badge, the width the closed shape already is.
struct LyricsStripView: View {
    let text: LyricsText

    var body: some View {
        LyricLineView(line: text.current)
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
