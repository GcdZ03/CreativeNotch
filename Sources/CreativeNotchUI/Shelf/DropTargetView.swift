import SwiftUI
import CreativeNotchCore

/// The dashed target the shelf shows when empty and the panel shows while a
/// drag is in flight (spec §5.4, §5.5). One view, two brightnesses: the
/// empty shelf is an explanation, the receiving state is an invitation.
struct DropTargetView: View {
    var prominent = false
    /// The shelf's expiry, for the dimmer target's promise. Only the empty
    /// shelf states it, so the receiving target leaves it at the default.
    var maxAge: TimeInterval? = ShelfStore.defaultMaxAge

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "arrow.down.doc")
                .notchFont(prominent ? 28 : 22, weight: .medium)
            Text(prominent ? String(localized: "Drop to stash on the shelf", bundle: .creativeNotch) : String(localized: "Drop files on the notch to stash them", bundle: .creativeNotch))
                .notchFont(prominent ? 14 : 12, weight: .medium, design: .rounded)
            if !prominent {
                Text(Self.retentionLine(maxAge: maxAge))
                    .notchFont(11, design: .rounded)
                    .foregroundStyle(.ink(0.4))
            }
        }
        .multilineTextAlignment(.center)
        .foregroundStyle(.ink(prominent ? 1 : 0.6))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.hairline(prominent ? 0.05 : 0))
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        .hairline(prominent ? 0.7 : 0.28),
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
                    )
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The store's `maxAge` in days, not a literal 7 — and, now the expiry is
    /// chosen in Settings (2026-10-24), no promise of an expiry at all when
    /// it is never. Static so the sentence is checked without rendering.
    static func retentionLine(maxAge: TimeInterval?) -> String {
        guard let maxAge else { return String(localized: "Kept until you remove them · drag them out anywhere", bundle: .creativeNotch) }
        let days = Int((maxAge / 86_400).rounded())
        return String(localized: "Kept \(days) days · drag them out anywhere", bundle: .creativeNotch)
    }
}
