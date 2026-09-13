import SwiftUI
import CreativeNotchCore

/// The shelf's contents, and the source of drags back out.
///
/// Items carry their real file URL, so any drop target accepts them —
/// Finder, an upload field, another app.
///
/// Empty, it shows the same dashed target the panel shows while a drag is
/// in flight, dimmer, with a sentence about what the shelf does. Full, it
/// shows tiles on a dark backing so a white document icon reads against
/// black, and a remove affordance on hover that calls `onRemove` — the same
/// `ShelfStore.remove(_:)` verb, which trashes an owned file, reached
/// through `AppState` like every other verb in the panel.
struct ShelfView: View {
    let store: ShelfStore
    var onRemove: (UUID) -> Void = { _ in }

    private let itemSize = CGSize(width: 64, height: 64)

    var body: some View {
        if store.items.isEmpty {
            DropTargetView()
        } else {
            // The width is read so the row can be *centred when it fits*.
            // `minWidth` is a floor, not a size: once the items are wider
            // than the pane the natural width wins and the row scrolls.
            GeometryReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(store.items) { item in
                            ShelfItemView(item: item, size: itemSize) { onRemove(item.id) }
                                .draggable(item.url)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
                    .frame(minWidth: proxy.size.width, alignment: .center)
                }
            }
        }
    }
}

private struct ShelfItemView: View {
    let item: ShelfItem
    let size: CGSize
    let onRemove: () -> Void

    @State private var image: NSImage?
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(0.07))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(.white.opacity(0.06), lineWidth: 1)
                    }

                Image(nsImage: image ?? ShelfThumbnails.shared.icon(for: item.url))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size.width - 20, height: size.height - 20)
                    .frame(width: size.width, height: size.height)

                if hovering {
                    Button(action: onRemove) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 16, height: 16)
                            .background(Circle().fill(Color(white: 0.22)))
                            .overlay(Circle().strokeBorder(.black, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .offset(x: 5, y: -5)
                    .accessibilityLabel("Remove \(item.displayName)")
                }
            }
            .frame(width: size.width, height: size.height)

            Text(item.displayName)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: size.width + 8)
        }
        // A tracking area inside the panel, alive only while the tile is.
        .onHover { hovering = $0 }
        .task {
            image = await ShelfThumbnails.shared.thumbnail(for: item.url, size: size)
        }
    }
}
