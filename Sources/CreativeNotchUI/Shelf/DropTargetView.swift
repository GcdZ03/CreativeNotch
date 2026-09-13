import SwiftUI
import CreativeNotchCore

/// The dashed target the shelf shows when empty and the panel shows while a
/// drag is in flight (spec §5.4, §5.5). One view, two brightnesses: the
/// empty shelf is an explanation, the receiving state is an invitation.
struct DropTargetView: View {
    var prominent = false

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: prominent ? 28 : 22, weight: .medium))
            Text(prominent ? "Drop to stash on the shelf" : "Drop files on the notch to stash them")
                .font(.system(size: prominent ? 14 : 12, weight: .medium, design: .rounded))
            if !prominent {
                Text("Kept \(Self.retentionDays) days · drag them out anywhere")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .multilineTextAlignment(.center)
        .foregroundStyle(.white.opacity(prominent ? 1 : 0.6))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.white.opacity(prominent ? 0.05 : 0))
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        .white.opacity(prominent ? 0.7 : 0.28),
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
                    )
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// `ShelfStore.maxAge` in days, not a literal 7.
    static var retentionDays: Int { Int(ShelfStore.maxAge / 86_400) }
}
