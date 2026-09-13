import AppKit
import SwiftUI
import CreativeNotchCore

/// How an entry reads in a list a few hundred points wide.
///
/// Pulled out of the view because views are not unit-tested here, and this
/// is the only part of the presentation with a right answer.
enum ClipboardPreview {

    static let maxCharacters = 80

    /// Truncation is a display concern only. The stored entry keeps every
    /// byte, so pasting it back gives the whole thing.
    static func text(for content: ClipboardContent) -> String {
        switch content {
        case .image(_, let ext):
            return "\(ext.uppercased()) image"

        case .text(let string):
            // Collapsed, not just trimmed: a copied code block rendered
            // with its newlines becomes one very tall row and pushes the
            // rest of the list off the panel.
            let collapsed = string
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")

            guard collapsed.count > maxCharacters else { return collapsed }
            return collapsed.prefix(maxCharacters) + "…"
        }
    }
}

/// The row's derived strings, kept out of the view so the argument order
/// into Core is pinned by a test — swapping `addedAt` and `now` compiles.
enum ClipboardRowModel {
    static func timeText(entry: ClipboardEntry, now: Date) -> String {
        ClipboardTimeLabel.text(addedAt: entry.addedAt, now: now)
    }
}

/// The clipboard history, and the source of paste-backs.
///
/// `now` is the single per-body instant `NotchRootView` binds, so every
/// row's time label comes from one reading of the clock and none of them
/// reads it again (spec §9).
struct ClipboardView: View {
    let store: ClipboardStore
    let now: Date
    let onPaste: (ClipboardEntry) -> Void

    var body: some View {
        if store.entries.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 22, weight: .medium))
                Text("Nothing copied yet")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
            }
            .foregroundStyle(.white.opacity(0.5))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(store.entries) { entry in
                        ClipboardRow(
                            entry: entry,
                            time: ClipboardRowModel.timeText(entry: entry, now: now)
                        ) {
                            onPaste(entry)
                        }
                    }
                }
            }
        }
    }
}

private struct ClipboardRow: View {
    let entry: ClipboardEntry
    let time: String
    let onPaste: () -> Void

    @State private var hovering = false

    private var kind: ClipboardKind { ClipboardKind.classify(entry.content) }

    var body: some View {
        Button(action: onPaste) {
            HStack(spacing: 9) {
                tile

                Text(ClipboardPreview.text(for: entry.content))
                    .font(kind == .code
                          ? .system(size: 11, design: .monospaced)
                          : .system(size: 12, design: .rounded))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 8)

                // A clock time at rest; the verb on hover.
                Text(hovering ? "Paste ↩" : time)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(hovering ? 0.7 : 0.4))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(.rect)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.white.opacity(hovering ? 0.08 : 0))
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("Paste \(ClipboardPreview.text(for: entry.content)), copied \(time)")
    }

    /// The image itself for an image; a glyph for everything else.
    @ViewBuilder
    private var tile: some View {
        Group {
            if case .image(let data, _) = entry.content, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.white.opacity(0.08))
                    Image(systemName: kind.symbolName)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .frame(width: 22, height: 22)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
