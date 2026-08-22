import SwiftUI
import CreativeNotchCore

/// The shelf's contents, and the source of drags back out.
///
/// Items carry their real file URL, so any drop target accepts them —
/// Finder, an upload field, another app.
struct ShelfView: View {
    let store: ShelfStore

    private let itemSize = CGSize(width: 56, height: 56)

    var body: some View {
        if store.items.isEmpty {
            Text("Drag files here")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(store.items) { item in
                        ShelfItemView(item: item, size: itemSize)
                            .draggable(item.url)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
    }
}

private struct ShelfItemView: View {
    let item: ShelfItem
    let size: CGSize

    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: image ?? ShelfThumbnails.shared.icon(for: item.url))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size.width, height: size.height)

            Text(item.displayName)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: size.width + 20)
        }
        .task {
            image = await ShelfThumbnails.shared.thumbnail(for: item.url, size: size)
        }
    }
}
