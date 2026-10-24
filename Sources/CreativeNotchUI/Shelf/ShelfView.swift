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
/// carries its verbs — Open, Quick Look, Show in Finder, AirDrop, Remove —
/// as accessibility actions and a context menu: VoiceOver and keyboard
/// users have no hover, and a right-click is the Mac's way to ask a thing
/// what it can do. Which verbs, and in what order, is Core's
/// (`ShelfTileVerb`).
///
/// A click selects a tile — a ring round it, and a line under the shelf
/// saying what Space and a double-click do — and a double-click opens it
/// with its default app, as in Finder. Space and ← → are the panel's keys,
/// handled by `AppDelegate.handlePanelKey`, so they work only while the
/// panel is key: after a click in it, or an open by tap or shortcut.
///
/// A file still copying in (`ShelfItem.isPending`) shows as its icon,
/// dimmed, under a small spinner, and VoiceOver reads it as "<name>,
/// copying". It has no verbs, cannot be selected and cannot be dragged:
/// there is no file behind it yet. The spinner is the shelf's one moving
/// part and exists only while a copy runs and the pane is on screen.
struct ShelfView: View {
    let store: ShelfStore
    var selection: UUID? = nil
    var onSelect: (UUID) -> Void = { _ in }
    var onRemove: (UUID) -> Void = { _ in }
    var onAirDrop: (URL) -> Void = { _ in }
    var onReveal: (URL) -> Void = { _ in }
    var onOpen: (UUID) -> Void = { _ in }
    var onQuickLook: (UUID) -> Void = { _ in }

    /// One verb a tile offers outside hover.
    struct TileAction {
        let verb: ShelfTileVerb
        let perform: () -> Void

        var label: String { verb.label }
        var symbolName: String { verb.symbolName }
        var isDestructive: Bool { verb.isDestructive }
    }

    /// The verbs `item` offers, in menu order — none while it is still
    /// copying in — each performing `perform(verb)`.
    ///
    /// Static, and the single list both the accessibility actions and the
    /// context menu are built from, so the two cannot drift apart and a
    /// test can check what neither exposes once rendered.
    static func tileActions(
        for item: ShelfItem,
        perform: @escaping (ShelfTileVerb) -> Void
    ) -> [TileAction] {
        ShelfTileVerb.verbs(for: item).map { verb in
            TileAction(verb: verb) { perform(verb) }
        }
    }

    /// Whether a tile can be dragged out. A pending item's URL names a file
    /// that does not exist yet; dropping it in Finder would copy nothing.
    static func isDraggable(_ item: ShelfItem) -> Bool {
        !item.isPending
    }

    /// The empty shelf's target, stating this store's expiry rather than the
    /// default one. Static so a test can check which age it was handed.
    static func emptyTarget(for store: ShelfStore) -> DropTargetView {
        DropTargetView(maxAge: store.maxAge)
    }

    /// What VoiceOver reads for a tile: the file's name, as shown under it,
    /// and that it is still copying while it is.
    static func tileAccessibilityLabel(for item: ShelfItem) -> String {
        item.isPending ? "\(item.displayName), copying" : item.displayName
    }

    /// Whether `item` is drawn selected: the selection names it and it can
    /// be selected at all. A tile that started copying after it was
    /// selected — it cannot, but the rule is not the view's to assume —
    /// draws no ring.
    static func isSelected(_ item: ShelfItem, selection: UUID?) -> Bool {
        item.id == selection && ShelfSelection.isSelectable(item)
    }

    /// The verb a tile's double-click and menu row reach.
    private func perform(_ verb: ShelfTileVerb, on item: ShelfItem) {
        switch verb {
        case .open:      onOpen(item.id)
        case .quickLook: onQuickLook(item.id)
        case .reveal:    onReveal(item.url)
        case .airDrop:   onAirDrop(item.url)
        case .remove:    onRemove(item.id)
        }
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
                            let tile = ShelfItemView(
                                item: item,
                                size: itemSize,
                                isSelected: Self.isSelected(item, selection: selection),
                                onSelect: { onSelect(item.id) },
                                perform: { perform($0, on: item) }
                            )
                            // Two branches, so a tile turning ready is a new
                            // view: its thumbnail task runs again, now that
                            // there is a file for QuickLook to read.
                            if Self.isDraggable(item) {
                                tile.draggable(item.url)
                            } else {
                                tile
                            }
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
    let isSelected: Bool
    let onSelect: () -> Void
    let perform: (ShelfTileVerb) -> Void

    @State private var image: NSImage?
    @State private var hovering = false

    private var actions: [ShelfView.TileAction] {
        ShelfView.tileActions(for: item, perform: perform)
    }

    private func onRemove() { perform(.remove) }
    private func onAirDrop() { perform(.airDrop) }

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                // Selected, the backing lifts and the border turns to ink —
                // the tab bar's selected fill, and a ring Increase Contrast
                // strengthens through `NotchInk`. No animation: a selection
                // is a state, not an event, so there is nothing for Reduce
                // Motion to take away.
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.hairline(isSelected ? 0.14 : 0.07))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(
                                isSelected ? AnyShapeStyle(.ink(0.85)) : AnyShapeStyle(.hairline(0.06)),
                                lineWidth: isSelected ? 2 : 1
                            )
                    }

                Image(nsImage: image ?? ShelfThumbnails.shared.icon(for: item.url))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size.width - 20, height: size.height - 20)
                    .frame(width: size.width, height: size.height)
                    .opacity(item.isPending ? 0.35 : 1)

                if item.isPending {
                    // Indeterminate: `copyItem` reports no progress, and a
                    // bar guessed from elapsed time would lie.
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .frame(width: size.width, height: size.height)
                }

                if hovering && !item.isPending {
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
                if hovering && !item.isPending {
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
                .foregroundStyle(.ink(isSelected ? 0.95 : 0.75))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: size.width + 8)
        }
        // A tracking area inside the panel, alive only while the tile is.
        .onHover { hovering = $0 }
        // Finder's pair: a click selects, a double-click opens. The click is
        // simultaneous rather than exclusive so selecting is immediate
        // instead of waiting out the double-click interval, and both pass a
        // copying tile by — it has no file to select or open.
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            guard !item.isPending else { return }
            perform(.open)
        }
        .simultaneousGesture(TapGesture().onEnded {
            guard !item.isPending else { return }
            onSelect()
        })
        // One element, not a picture, a caption and two buttons that come
        // and go with the pointer: the hover buttons' verbs are its actions.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ShelfView.tileAccessibilityLabel(for: item))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
            // Nothing to preview until the copy lands; the icon stands in.
            guard !item.isPending else { return }
            image = await ShelfThumbnails.shared.thumbnail(for: item, size: size)
        }
    }
}
