import AppKit
import SwiftUI
import CreativeNotchCore

/// One line of lyrics, as the strip under the closed notch and the music
/// peek's row draw it (spec 2026-10-29).
///
/// Redrawn only when the line changes -- the controller's one-shot, about
/// every four seconds -- and **swapped, not faded.** Measured on the real app
/// on 2026-10-29 with a song playing: a 0.3s cross-fade on each line cost
/// 1.42% of a core, because SwiftUI drives every frame of it in-process; the
/// plain swap costs about 0.2%, against 0.03% with lyrics off. Nothing here loops
/// or reads a clock. A break between lines, or the wait before
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
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: size - 2, weight: .semibold))
                    .foregroundStyle(.ink(opacity * 0.5))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityText(for: line))
    }

    /// The smallest the line is drawn before it is cut: 75% of 12pt.
    static let minimumScale: CGFloat = 0.75

    /// Whether `line` fits `width` points at the smallest size the strip
    /// will draw it, in the strip's own font -- measured, not counted, so a
    /// line of narrow letters is not split for nothing (2026-10-29).
    static func fits(_ line: String, width: CGFloat, size: CGFloat = 12) -> Bool {
        let base = NSFont.systemFont(ofSize: size * minimumScale, weight: .semibold)
        let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 0) } ?? base
        return (line as NSString).size(withAttributes: [.font: font]).width <= width
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

    static let horizontalPadding: CGFloat = 12

    var body: some View {
        LyricLineView(line: text.current)
            .padding(.horizontal, Self.horizontalPadding)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
