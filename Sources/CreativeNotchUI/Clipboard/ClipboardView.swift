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
            return String(localized: "\(ext.uppercased()) image", bundle: .creativeNotch, comment: "A copied image: PNG image")

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
    static let copiedAnnouncement = String(localized: "Copied", bundle: .creativeNotch)

    /// A clock time at rest, the verb on hover, and the confirmation after
    /// a click. The confirmation wins over hover: the pointer is still on
    /// the row it clicked, and "Copy" there would read as nothing having
    /// happened.
    static func trailingText(time: String, hovering: Bool, copied: Bool) -> String {
        if copied { return String(localized: "Copied ✓", bundle: .creativeNotch) }
        return hovering ? String(localized: "Copy", bundle: .creativeNotch) : time
    }

    /// "Pinned" leads, so VoiceOver says it before the content: the pins
    /// are the top of the list, and a VoiceOver user should hear where the
    /// pins end as a sighted one sees the glyph stop.
    static func accessibilityLabel(entry: ClipboardEntry, time: String) -> String {
        let label = String(localized: "Copy \(ClipboardPreview.text(for: entry.content)), added \(time)", bundle: .creativeNotch)
        return entry.isPinned ? String(localized: "Pinned, \(label)", bundle: .creativeNotch) : label
    }

    /// What VoiceOver hears after Pin or Unpin. The row moves when pinned —
    /// to the top — so the VoiceOver cursor is left on whatever slid into
    /// its place, and without this nothing would say the action worked.
    static func pinAnnouncement(pinned: Bool) -> String {
        pinned ? String(localized: "Pinned", bundle: .creativeNotch) : String(localized: "Unpinned", bundle: .creativeNotch)
    }

    /// The pane's line when a search keeps nothing. It repeats the query, so
    /// the reason the list is empty is on screen rather than in the field
    /// above, where a typo is easy to miss.
    static func noMatchesText(query: String) -> String {
        String(localized: "No matches for “\(query.trimmingCharacters(in: .whitespacesAndNewlines))”", bundle: .creativeNotch)
    }

    /// One verb a row offers beyond hover.
    struct RowAction {
        let label: String
        let symbolName: String
        let isDestructive: Bool
        /// What pressing the row already does. VoiceOver reaches it as the
        /// row's own press, so it is left out of the named actions rather
        /// than offered twice.
        let isDefault: Bool
        /// Shown greyed in the menu when `false`. Only Pin is ever disabled,
        /// at `ClipboardStore.maxPinned`.
        var isEnabled = true
        let perform: () -> Void
    }

    /// The row's verbs, in menu order — the shelf tile's words and symbols
    /// for the same ideas, with Remove last where the destructive verb sits.
    ///
    /// The single list the context menu and the accessibility actions are
    /// both built from, as `ShelfView.tileActions` is, so the two cannot
    /// drift apart. Remove used to live only in the menu, which a VoiceOver
    /// user rarely opens; from here it is also in the rotor's Actions.
    ///
    /// At the pin limit, Pin stays in the menu, greyed, saying why, rather
    /// than vanishing: a verb that comes and goes reads as a bug. Unpin is
    /// never disabled — it is how the limit is got under.
    static func rowActions(
        isPinned: Bool,
        canPin: Bool,
        onCopy: @escaping () -> Void,
        onTogglePin: @escaping () -> Void,
        onRemove: @escaping () -> Void
    ) -> [RowAction] {
        let pin: RowAction = isPinned
            ? RowAction(label: String(localized: "Unpin", bundle: .creativeNotch), symbolName: "pin.slash",
                        isDestructive: false, isDefault: false, perform: onTogglePin)
            : RowAction(label: canPin
                            ? String(localized: "Pin", bundle: .creativeNotch)
                            : String(localized: "Pin (\(ClipboardStore.maxPinned) already pinned)", bundle: .creativeNotch),
                        symbolName: "pin",
                        isDestructive: false, isDefault: false, isEnabled: canPin,
                        perform: onTogglePin)
        return [
            RowAction(label: String(localized: "Copy", bundle: .creativeNotch), symbolName: "doc.on.doc",
                      isDestructive: false, isDefault: true, perform: onCopy),
            pin,
            RowAction(label: String(localized: "Remove", bundle: .creativeNotch), symbolName: "xmark",
                      isDestructive: true, isDefault: false, perform: onRemove),
        ]
    }

    /// The named actions VoiceOver offers: everything but the row's own
    /// press, and nothing disabled — an accessibility action cannot be
    /// greyed, so a disabled one would be a verb that silently did nothing.
    static func accessibilityActions(_ actions: [RowAction]) -> [RowAction] {
        actions.filter { !$0.isDefault && $0.isEnabled }
    }
}

/// The clipboard history, and the source of copy-backs.
///
/// `now` is the single per-body instant `NotchRootView` binds, so every
/// row's time label comes from one reading of the clock and none of them
/// reads it again (spec §9).
///
/// The search field sits above the list once there is anything to search,
/// and filters it as you type (`ClipboardSearch`). Its text lives in
/// `AppState.clipboardQuery`, bound in here, because Esc has to read it.
/// Pins lead the list (`ClipboardStore.entries` is already in that order);
/// a filtered list keeps that order, so a matching pin is still on top.
struct ClipboardView: View {
    let store: ClipboardStore
    let now: Date
    var query: Binding<String> = .constant("")
    let onCopy: (ClipboardEntry) -> Void
    var onTogglePin: (UUID) -> Void = { _ in }
    var onRemove: (UUID) -> Void = { _ in }

    var body: some View {
        if store.entries.isEmpty {
            placeholder(symbol: "doc.on.clipboard", text: String(localized: "Nothing copied yet", bundle: .creativeNotch))
        } else {
            VStack(alignment: .leading, spacing: 8) {
                NotchSearchField(prompt: String(localized: "Search clipboard", bundle: .creativeNotch), text: query)

                let shown = ClipboardSearch.filter(store.entries, query: query.wrappedValue)
                if shown.isEmpty {
                    placeholder(symbol: "magnifyingglass",
                                text: ClipboardRowModel.noMatchesText(query: query.wrappedValue))
                } else {
                    ScrollView(.vertical, showsIndicators: false) { rows(shown) }
                }
            }
        }
    }

    private func rows(_ shown: [ClipboardEntry]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(shown) { entry in
                ClipboardRow(
                    entry: entry,
                    time: ClipboardRowModel.timeText(entry: entry, now: now),
                    canPin: store.canPin,
                    onCopy: { onCopy(entry) },
                    onTogglePin: { onTogglePin(entry.id) },
                    onRemove: { onRemove(entry.id) }
                )
            }
        }
    }

    private func placeholder(symbol: String, text: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .notchFont(22, weight: .medium)
            Text(text)
                .notchFont(12, weight: .medium, design: .rounded)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(.ink(0.5))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ClipboardRow: View {
    let entry: ClipboardEntry
    let time: String
    let canPin: Bool
    let onCopy: () -> Void
    let onTogglePin: () -> Void
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
                    .notchFont(kind == .code ? 11 : 12, design: kind == .code ? .monospaced : .rounded)
                    .foregroundStyle(.ink(0.88))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 8)

                // A pin is shown, not only ordered: the list's top rows
                // being pins is otherwise indistinguishable from their
                // being the latest copies. Hidden from VoiceOver, whose
                // label already leads with "Pinned".
                if entry.isPinned {
                    Image(systemName: "pin.fill")
                        .notchFont(9, weight: .semibold)
                        .foregroundStyle(.ink(0.6))
                        .rotationEffect(.degrees(45))
                        .accessibilityHidden(true)
                }

                // A clock time at rest, the verb on hover, the
                // confirmation after a click.
                Text(ClipboardRowModel.trailingText(time: time, hovering: hovering, copied: copied))
                    .notchFont(10, weight: .medium, design: .rounded)
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
            ForEach(actions, id: \.label) { action in
                Button(role: action.isDestructive ? .destructive : nil, action: action.perform) {
                    Label(action.label, systemImage: action.symbolName)
                }
                .disabled(!action.isEnabled)
            }
        }
        .onDisappear { confirmation?.cancel() }
        .accessibilityLabel(ClipboardRowModel.accessibilityLabel(entry: entry, time: time))
        // Copy stays the button's press, VoiceOver's default action; the
        // rest of the menu is offered as named actions.
        .accessibilityActions {
            ForEach(ClipboardRowModel.accessibilityActions(actions), id: \.label) { action in
                Button(action.label, action: action.perform)
            }
        }
    }

    private var actions: [ClipboardRowModel.RowAction] {
        ClipboardRowModel.rowActions(
            isPinned: entry.isPinned, canPin: canPin,
            onCopy: copy, onTogglePin: togglePin, onRemove: onRemove)
    }

    /// Pins or unpins through the verb, then says so to VoiceOver — the row
    /// is about to move out from under its cursor.
    private func togglePin() {
        let pinning = !entry.isPinned
        onTogglePin()
        AccessibilityNotification.Announcement(ClipboardRowModel.pinAnnouncement(pinned: pinning)).post()
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
                        .notchFont(10, weight: .semibold)
                        .foregroundStyle(.ink(0.7))
                }
            }
        }
        .notchFrame(width: 22, height: 22)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
