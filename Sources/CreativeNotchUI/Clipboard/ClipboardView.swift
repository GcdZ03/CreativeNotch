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

/// The clipboard history, and the source of paste-backs.
struct ClipboardView: View {
    let store: ClipboardStore
    let onPaste: (ClipboardEntry) -> Void

    var body: some View {
        if store.entries.isEmpty {
            Text("Nothing copied yet")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(store.entries) { entry in
                        Button {
                            onPaste(entry)
                        } label: {
                            ClipboardRow(entry: entry)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
        }
    }
}

private struct ClipboardRow: View {
    let entry: ClipboardEntry

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.45))
                .frame(width: 14)

            Text(ClipboardPreview.text(for: entry.content))
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .contentShape(.rect)
        .background {
            RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.05))
        }
    }

    private var icon: String {
        switch entry.content {
        case .text:  return "text.alignleft"
        case .image: return "photo"
        }
    }
}
