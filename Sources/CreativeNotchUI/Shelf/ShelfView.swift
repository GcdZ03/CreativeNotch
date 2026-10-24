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
/// black, and on hover a remove affordance that calls `onRemove` — the same
/// `ShelfStore.remove(_:)` verb, which trashes an owned file, reached
/// through `AppState` like every other verb in the panel — and an AirDrop
/// one that calls `onAirDrop` with the file's URL.
///
/// Those two buttons exist only under the pointer, so each tile also
/// carries the same verbs, plus Show in Finder, as accessibility actions
/// and a context menu: VoiceOver and keyboard users have no hover, and a
/// right-click is the Mac's way to ask a thing what it can do.
struct ShelfView: View {
    let store: ShelfStore
    var onRemove: (UUID) -> Void = { _ in }
    var onAirDrop: (URL) -> Void = { _ in }
    var onReveal: (URL) -> Void = { _ in }

    /// One verb a tile offers outside hover.
    struct TileAction {
        let label: String
        let symbolName: String
        let isDestructive: Bool
        let perform: () -> Void
    }

    /// The tile's verbs, in menu order: Show in Finder, AirDrop, then
    /// Remove last, where the destructive verb sits in the title row too.
    ///
    /// Static, and the single list both the accessibility actions and the
    /// context menu are built from, so the two cannot drift apart and a
    /// test can check what neither exposes once rendered.
    static func tileActions(
        onRemove: @escaping () -> Void,
        onAirDrop: @escaping () -> Void,
        onReveal: @escaping () -> Void
    ) -> [TileAction] {
        [
            TileAction(label: "Show in Finder", symbolName: "folder",
                       isDestructive: false, perform: onReveal),
            TileAction(label: "AirDrop", symbolName: "dot.radiowaves.left.and.right",
                       isDestructive: false, perform: onAirDrop),
            TileAction(label: "Remove", symbolName: "xmark",
                       isDestructive: true, perform: onRemove),
        ]
    }

    /// The empty shelf's target, stating this store's expiry rather than the
    /// default one. Static so a test can check which age it was handed.
    static func emptyTarget(for store: ShelfStore) -> DropTargetView {
        DropTargetView(maxAge: store.maxAge)
    }

    /// What VoiceOver reads for a tile: the file's name, as shown under it.
    static func tileAccessibilityLabel(for item: ShelfItem) -> String {
        item.displayName
    }

    @Environment(\.notchTextScale) private var textScale

    /// A tile, grown with the text size so the name under it keeps its
    /// width in characters -- and the thumbnail asked for at that size.
    private var itemSize: CGSize {
        let side = NotchType.length(64, scale: textScale)
        return CGSize(width: side, height: side)
    }

    var body: some View {
        content
            // A file moved or deleted behind the shelf's back is noticed
            // here, when its tile would be seen, rather than by watching
            // the disk: one `fileExists` per item each time the shelf opens.
            .onAppear { store.pruneMissing() }
    }

    @ViewBuilder
    private var content: some View {
        if store.items.isEmpty {
            Self.emptyTarget(for: store)
        } else {
            // The width is read so the row can be *centred when it fits*.
            // `minWidth` is a floor, not a size: once the items are wider
            // than the pane the natural width wins and the row scrolls.
            GeometryReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(store.items) { item in
                            ShelfItemView(
                                item: item,
                                size: itemSize,
                                onRemove: { onRemove(item.id) },
                                onAirDrop: { onAirDrop(item.url) },
                                onReveal: { onReveal(item.url) }
                            )
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
    let onAirDrop: () -> Void
    let onReveal: () -> Void

    @State private var image: NSImage?
    @State private var hovering = false

    private var actions: [ShelfView.TileAction] {
        ShelfView.tileActions(onRemove: onRemove, onAirDrop: onAirDrop, onReveal: onReveal)
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.hairline(0.07))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(.hairline(0.06), lineWidth: 1)
                    }

                Image(nsImage: image ?? ShelfThumbnails.shared.icon(for: item.url))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size.width - 20, height: size.height - 20)
                    .frame(width: size.width, height: size.height)

                if hovering {
                    Button(action: onRemove) {
                        Image(systemName: "xmark")
                            .notchFont(8, weight: .bold)
                            .foregroundStyle(.white)
                            .notchFrame(width: 16, height: 16)
                            .background(Circle().fill(Color(white: 0.22)))
                            .overlay(Circle().strokeBorder(.black, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .offset(x: 5, y: -5)
                    .accessibilityLabel("Remove \(item.displayName)")
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if hovering {
                    Button(action: onAirDrop) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .notchFont(9, weight: .bold)
                            .foregroundStyle(.white)
                            .notchFrame(width: 18, height: 18)
                            .background(Circle().fill(Color.accentColor.opacity(0.9)))
                            .overlay(Circle().strokeBorder(.black, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .offset(x: 5, y: 5)
                    .help("AirDrop")
                    .accessibilityLabel("AirDrop \(item.displayName)")
                }
            }
            .frame(width: size.width, height: size.height)

            Text(item.displayName)
                .notchFont(10, weight: .medium, design: .rounded)
                .foregroundStyle(.ink(0.75))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: size.width + 8)
        }
        // A tracking area inside the panel, alive only while the tile is.
        .onHover { hovering = $0 }
        // One element, not a picture, a caption and two buttons that come
        // and go with the pointer: the hover buttons' verbs are its actions.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ShelfView.tileAccessibilityLabel(for: item))
        .accessibilityActions {
            ForEach(actions, id: \.label) { action in
                Button(action.label, action: action.perform)
            }
        }
        .contextMenu {
            ForEach(actions, id: \.label) { action in
                Button(role: action.isDestructive ? .destructive : nil, action: action.perform) {
                    Label(action.label, systemImage: action.symbolName)
                }
            }
        }
        .task {
            image = await ShelfThumbnails.shared.thumbnail(for: item, size: size)
        }
    }
}
