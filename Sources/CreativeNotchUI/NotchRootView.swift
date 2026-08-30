import SwiftUI
import CreativeNotchCore

/// The single funnel every derived value hangs off.
///
/// `state`, `anchor` and `panelFrame` are all `private(set)`: the hover
/// tracking rect, the hit-test region and the drawn shape are *derived*
/// from them, so every change has to be followed by a re-sync. Assigning
/// them directly left the tracking rect describing the previous
/// presentation — harmless for a hover-driven peek, fatal for a
/// programmatic state like `.receiving`, where a stale rect turns a drag
/// moving below the notch into a `mouseExited` that tears the drop target
/// down mid-drag.
@Observable
public final class AppState {

    public private(set) var state: NotchState = .closed

    /// Where the panel attaches on the current screen.
    public private(set) var anchor: CreativeNotchCore.Anchor = .pill(.zero)

    /// The window's frame. Needed alongside the anchor because the drawn
    /// rect and the hit-test rect are both panel-*local*.
    public private(set) var panelFrame: CGRect = .zero

    /// The tab the panel was last opened on.
    ///
    /// Reopening returns here rather than always to the shelf. Only
    /// `.open` touches it: HUD peeks fire constantly, and letting one
    /// reset the tab would move the panel out from under the user for
    /// reasons they never see.
    ///
    /// Qualified because SwiftUI has a `Tab` of its own, the same reason
    /// `anchor` spells out `CreativeNotchCore.Anchor`.
    public private(set) var lastOpenTab: CreativeNotchCore.Tab = .shelf

    /// What an observer is told about.
    public enum Change: Equatable, Sendable {
        case state(NotchState)
        case geometry(anchor: CreativeNotchCore.Anchor, panelFrame: CGRect)
    }

    public struct ObserverToken: Hashable, Sendable {
        fileprivate let id: UUID
    }

    /// Set once at install.
    ///
    /// `@ObservationIgnored` because the store publishes its own changes —
    /// it is `@Observable`, so the view redraws from the store rather than
    /// from this reference, and re-assigning it must not invalidate a
    /// view.
    @ObservationIgnored
    public var shelf: ShelfStore?

    /// Set once at install, like `shelf`. `@ObservationIgnored` because
    /// the store publishes its own changes — it is `@Observable`, so the
    /// view redraws from the store rather than from this reference.
    @ObservationIgnored
    public var clipboard: ClipboardStore?

    /// How the view asks for an entry to be put back on the pasteboard.
    ///
    /// A closure rather than a `ClipboardController` reference, so the
    /// view layer never gains a way to start or stop the poller.
    @ObservationIgnored
    public var onPasteClipboard: ((ClipboardEntry) -> Void)?

    /// How the media buttons reach `MediaRemoteBridge`.
    ///
    /// A closure rather than calling the bridge from the view, for the
    /// same reason `onPasteClipboard` is one: it keeps a real transport
    /// command — which changes playback on the machine — out of anything
    /// a test constructs.
    @ObservationIgnored
    public var onMediaCommand: ((MediaCommand) -> Void)?

    /// Whether to show the media row at all.
    ///
    /// Set once at install from `MediaRemoteBridge.isAvailable`. Buttons
    /// that resolve to nothing would look identical to working ones and
    /// silently do nothing, which is worse than not offering them.
    ///
    /// Not `@ObservationIgnored`: unlike `shelf` / `clipboard`, which
    /// publish their own changes, this is a plain `Bool` that `body` reads
    /// directly — it needs Observation's tracking to invalidate the view
    /// if it is ever written again after install.
    public var showsMediaControls: Bool = false

    /// Set by `MediaController`. Observable — unlike `shelf` and
    /// `clipboard`, which are `@Observable` stores that publish their own
    /// changes, this is a plain value the header reads directly.
    public internal(set) var nowPlaying: TrackSnapshot?
    public internal(set) var nowPlayingArtwork: Data?

    /// A list, not a single closure.
    ///
    /// It was one closure, which meant the second registration silently
    /// replaced the first. `AppDelegate` registers the tracking-rect
    /// re-sync and the outside-click monitor here, and every planned
    /// module will want its own — under the old shape the first of them to
    /// arrive would have taken both of those with it, at runtime, with no
    /// compiler help. (Follow-up F2.)
    ///
    /// `@ObservationIgnored` because it is wiring, not observable state:
    /// registering must never invalidate a SwiftUI view.
    @ObservationIgnored
    private var observers: [(token: ObserverToken, handler: (Change) -> Void)] = []

    public init() {}

    /// Registers `handler`, returning a token that removes it.
    @discardableResult
    public func observe(_ handler: @escaping (Change) -> Void) -> ObserverToken {
        let token = ObserverToken(id: UUID())
        observers.append((token, handler))
        return token
    }

    /// How many handlers are registered. Exposed so a caller that
    /// re-registers (`AppDelegate.install`) can be shown not to stack.
    var observerCount: Int { observers.count }

    public func removeObserver(_ token: ObserverToken) {
        observers.removeAll { $0.token == token }
    }

    /// The only way `state` ever changes.
    ///
    /// Equal transitions are dropped: `@Observable` does not dedupe, and a
    /// redundant assignment would force a redraw for no visible difference.
    /// The derived rects are functions of the state, so skipping the
    /// callback for an unchanged state cannot leave them stale.
    public func transition(to next: NotchState) {
        guard next != state else { return }
        if case .open(let tab) = next { lastOpenTab = tab }
        state = next
        notify(.state(next))
    }

    /// The only way the geometry ever changes. Returns whether anything
    /// actually moved, so callers can skip the work that follows.
    @discardableResult
    public func setGeometry(
        anchor newAnchor: CreativeNotchCore.Anchor,
        panelFrame newFrame: CGRect
    ) -> Bool {
        guard newAnchor != anchor || newFrame != panelFrame else { return false }
        anchor = newAnchor
        panelFrame = newFrame
        notify(.geometry(anchor: newAnchor, panelFrame: newFrame))
        return true
    }

    private func notify(_ change: Change) {
        for observer in observers { observer.handler(change) }
    }
}

public struct NotchRootView: View {
    @Bindable var app: AppState

    public init(app: AppState) {
        self.app = app
    }

    /// The drawn region, in the top-left-origin space SwiftUI lays out in.
    ///
    /// Derived from `NotchShape.visibleRect` — the same tested function the
    /// hit test uses — rather than from a second `switch` over the
    /// presentation. Two independent derivations of one rectangle is the
    /// exact shape of this project's only Critical bug. (Follow-up F5.)
    static func drawnRect(
        state: NotchState,
        anchor: CreativeNotchCore.Anchor,
        panelFrame: CGRect
    ) -> CGRect {
        let visible = NotchShape.visibleRect(
            presentation: state.presentation,
            anchor: anchor,
            panelFrame: panelFrame
        )
        return CGRect(
            x: visible.minX,
            y: panelFrame.height - visible.maxY,
            width: visible.width,
            height: visible.height
        )
    }

    private var drawn: CGRect {
        Self.drawnRect(state: app.state, anchor: app.anchor, panelFrame: app.panelFrame)
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            shape
                .frame(width: drawn.width, height: drawn.height)
                .offset(x: drawn.minX, y: drawn.minY)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: app.state)
    }

    /// Derived from `NotchShape.cornerRadii` — the same tested function
    /// that decides the drawn rect — rather than from a second `switch`
    /// here. Two independent derivations of one shape is the exact shape
    /// of this project's only Critical bug.
    private var backgroundShape: AnyShape {
        let r = NotchShape.cornerRadii(
            presentation: app.state.presentation,
            anchor: app.anchor
        )
        return AnyShape(UnevenRoundedRectangle(
            topLeadingRadius: r.topLeading,
            bottomLeadingRadius: r.bottomLeading,
            bottomTrailingRadius: r.bottomTrailing,
            topTrailingRadius: r.topTrailing
        ))
    }

    private var shape: some View {
        backgroundShape
            .fill(.black)
            .overlay {
                switch app.state {
                case .closed:
                    EmptyView()

                case .open(let tab):
                    VStack(spacing: 0) {
                        mediaBar
                        PanelTabBar(selected: tab) { app.transition(to: .open($0)) }
                        openContent(for: tab)
                    }
                    // Top-aligned, but *below the anchor* — not at the
                    // panel's absolute top. `panelFrame` puts the panel's
                    // top edge at `anchor.rect.maxY`, so its first band is
                    // the hardware notch (or, on a pill Mac, the menu bar
                    // it sits under). Pinning to the true top hid the media
                    // row behind the notch entirely while leaving the tab
                    // bar just low enough to still show — the panel looked
                    // like the module had not shipped.
                    .padding(.top, app.anchor.rect.height)
                    .frame(maxHeight: .infinity, alignment: .top)

                case .receiving:
                    Text("Drop here")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))

                case .peek(.hud(let event)):
                    HUDView(
                        kind: event.kind,
                        notchGap: app.anchor.isNotch ? app.anchor.rect.width : 0
                    )

                // A peek is a glance, not a panel: one truncating line, no
                // artwork. The spec excludes artwork here deliberately —
                // the cache can legitimately be empty at the moment the
                // peek fires, and a tile that appears a beat later would
                // shove the text sideways on the closed notch.
                //
                // Without this case the state fell through to `default`
                // and drew the literal string "CreativeNotch" over playing
                // music — the ambient peek this whole module exists for
                // was never once drawn. Text comes from
                // `NowPlayingLabel.text(for:)`, the same function the
                // panel header uses, so the two cannot drift apart.
                case .peek(.nowPlaying(let track)):
                    // Same notch-gap treatment `HUDView` gets above: on a
                    // notched Mac the middle of this band is the camera
                    // housing, and a centred line renders straight behind
                    // it. Zero on a pill Mac and on external displays.
                    NowPlayingPeekView(
                        track: track,
                        notchGap: app.anchor.isNotch ? app.anchor.rect.width : 0
                    )

                default:
                    Text(label)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
            .onTapGesture {
                // Through the funnel, like every other mutation.
                switch app.state {
                case .open:  app.transition(to: .closed)
                default:     app.transition(to: .open(app.lastOpenTab))
                }
            }
    }

    /// What is playing, and the controls for it, as ONE full-width bar.
    ///
    /// They were previously two rows: a left-aligned header above centred
    /// buttons. That put two alignment systems in one panel, left the whole
    /// right half of the header empty, and floated the transport controls
    /// away from the track they operate on. A bar that spans the panel does
    /// not read as "left-aligned" at all, so the centred tab bar below it
    /// sits in a different register rather than in conflict.
    ///
    /// The divider is structure, not decoration: above it is what is
    /// playing now, below it is what you have stored. Two different
    /// concerns, and the panel is small enough that the seam has to be
    /// stated rather than implied by space.
    @ViewBuilder
    private var mediaBar: some View {
        let hasMedia = app.nowPlaying != nil || app.showsMediaControls

        if hasMedia {
            HStack(spacing: 12) {
                if let nowPlaying = app.nowPlaying {
                    NowPlayingView(snapshot: nowPlaying, artwork: app.nowPlayingArtwork)
                }

                // Keeps the controls hard right when a track is showing,
                // and lets them sit centred on their own when nothing is
                // playing — the helper may be starting, degraded, or the
                // machine simply silent, and transport still works in all
                // three.
                Spacer(minLength: 12)

                if app.showsMediaControls {
                    MediaControlsView { app.onMediaCommand?($0) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 12)

            Divider()
                .overlay(.white.opacity(0.10))
                .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private func openContent(for tab: CreativeNotchCore.Tab) -> some View {
        switch tab {
        case .shelf:
            if let shelf = app.shelf { ShelfView(store: shelf) }
        case .clipboard:
            if let clipboard = app.clipboard {
                ClipboardView(store: clipboard) { entry in
                    app.onPasteClipboard?(entry)
                }
            }
        case .hud:
            // Not built. `PanelTabBar.visible` does not offer this tab, so
            // it is unreachable — but `Tab` is exhaustive and the compiler
            // wants a case.
            EmptyView()
        }
    }

    private var label: String {
        switch app.state {
        case .closed:          return ""
        case .peek:            return "CreativeNotch"
        case .open(let tab):   return tab.rawValue.capitalized
        case .receiving:       return "Drop here"
        }
    }
}
