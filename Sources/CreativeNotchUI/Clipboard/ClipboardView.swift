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
    /// byte, so copying it back gives the whole thing.
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
///
/// The verb is "Copy", never "Paste": clicking a row writes the entry back
/// to the pasteboard and stops there. The app deliberately holds no
/// Accessibility permission, so it cannot send the keystroke a paste
/// would need (see `NSPasteboard.write(_:)`).
enum ClipboardRowModel {
    static func timeText(entry: ClipboardEntry, now: Date) -> String {
        ClipboardTimeLabel.text(addedAt: entry.addedAt, now: now)
    }

    /// How long a clicked row says "Copied ✓" before going back to its
    /// time. Run as one `Task.sleep` per click, never a repeating timer.
    static let confirmationDuration: Duration = .milliseconds(1200)

    /// What VoiceOver hears when a row is clicked. The row's label does
    /// not change under the VoiceOver cursor, so without this a VoiceOver
    /// user gets no sign the click did anything.
    static let copiedAnnouncement = "Copied"

    /// A clock time at rest, the verb on hover, and the confirmation after
    /// a click. The confirmation wins over hover: the pointer is still on
    /// the row it clicked, and "Copy" there would read as nothing having
    /// happened.
    static func trailingText(time: String, hovering: Bool, copied: Bool) -> String {
        if copied { return "Copied ✓" }
        return hovering ? "Copy" : time
    }

    static func accessibilityLabel(entry: ClipboardEntry, time: String) -> String {
        "Copy \(ClipboardPreview.text(for: entry.content)), added \(time)"
    }
}

/// The clipboard history, and the source of copy-backs.
///
/// `now` is the single per-body instant `NotchRootView` binds, so every
/// row's time label comes from one reading of the clock and none of them
/// reads it again (spec §9).
struct ClipboardView: View {
    let store: ClipboardStore
    let now: Date
    let onCopy: (ClipboardEntry) -> Void
    var onRemove: (UUID) -> Void = { _ in }

    var body: some View {
        if store.entries.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 22, weight: .medium))
                Text("Nothing copied yet")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
            }
            .foregroundStyle(.ink(0.5))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(store.entries) { entry in
                        ClipboardRow(
                            entry: entry,
                            time: ClipboardRowModel.timeText(entry: entry, now: now),
                            onCopy: { onCopy(entry) },
                            onRemove: { onRemove(entry.id) }
                        )
                    }
                }
            }
        }
    }
}

private struct ClipboardRow: View {
    let entry: ClipboardEntry
    let time: String
    let onCopy: () -> Void
    let onRemove: () -> Void

    @State private var hovering = false

    /// True for `confirmationDuration` after a click. The row keeps it
    /// across the promotion its own copy causes: `ForEach` is keyed on the
    /// entry's id, which promotion preserves, so the row moves to the top
    /// rather than being rebuilt.
    @State private var copied = false

    /// The pending one-shot that clears `copied`. Replaced, not stacked,
    /// on a second click, so the label stays up a full duration after the
    /// latest one.
    @State private var confirmation: Task<Void, Never>?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var kind: ClipboardKind { ClipboardKind.classify(entry.content) }

    var body: some View {
        Button(action: copy) {
            HStack(spacing: 9) {
                tile

                Text(ClipboardPreview.text(for: entry.content))
                    .font(kind == .code
                          ? .system(size: 11, design: .monospaced)
                          : .system(size: 12, design: .rounded))
                    .foregroundStyle(.ink(0.88))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 8)

                // A clock time at rest, the verb on hover, the
                // confirmation after a click.
                Text(ClipboardRowModel.trailingText(time: time, hovering: hovering, copied: copied))
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.ink(copied || hovering ? 0.7 : 0.4))
                    .contentTransition(reduceMotion ? .opacity : .interpolate)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(.rect)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.hairline(hovering ? 0.08 : 0))
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        // The shelf tile's words and symbols for the same idea: taking one
        // item off a panel list is "Remove", with the xmark, on both.
        .contextMenu {
            Button(action: copy) {
                Label("Copy", systemImage: "doc.on.doc")
            }
            Button(role: .destructive, action: onRemove) {
                Label("Remove", systemImage: "xmark")
            }
        }
        .onDisappear { confirmation?.cancel() }
        .accessibilityLabel(ClipboardRowModel.accessibilityLabel(entry: entry, time: time))
    }

    /// Copies, then confirms on this row for a moment. The reset is a
    /// one-shot `Task`, the precedent `HoverTracker`'s dwell set: nothing
    /// is scheduled until a click, and nothing outlives the row.
    private func copy() {
        onCopy()
        AccessibilityNotification.Announcement(ClipboardRowModel.copiedAnnouncement).post()

        withAnimation(swap) { copied = true }
        confirmation?.cancel()
        confirmation = Task { @MainActor in
            try? await Task.sleep(for: ClipboardRowModel.confirmationDuration)
            guard !Task.isCancelled else { return }
            withAnimation(swap) { copied = false }
        }
    }

    /// A short ease under Reduce Motion, the substitution `RollingDigits`
    /// makes; with it on, the label fades rather than morphs.
    private var swap: Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .snappy(duration: 0.25)
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
                        .fill(.hairline(0.08))
                    Image(systemName: kind.symbolName)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.ink(0.7))
                }
            }
        }
        .frame(width: 22, height: 22)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
