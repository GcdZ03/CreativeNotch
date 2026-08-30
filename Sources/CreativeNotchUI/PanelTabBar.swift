import SwiftUI
import CreativeNotchCore

public extension CreativeNotchCore.Tab {
    var title: String {
        switch self {
        case .shelf:     return "Shelf"
        case .clipboard: return "Clipboard"
        case .hud:       return "HUD"
        case .timer:     return "Timer"
        }
    }
}

/// The switcher inside the open panel.
///
/// Before this, tapping the notch always opened the shelf and
/// `.open(.clipboard)` fell through to a placeholder label — so the
/// clipboard was unreachable. A module nobody can open is not finished,
/// which is why the switcher lands with it.
struct PanelTabBar: View {

    /// Only tabs that have something behind them.
    ///
    /// `.hud` stays in the `Tab` enum because `PeekArbiter` and
    /// `AppDelegate` reference it, but HUD history is not built. A tab
    /// that opens onto a placeholder is worse than no tab.
    ///
    /// `.timer` is here because the opposite now holds for it: the tab has
    /// real content (`TimerTabView`), a real controller behind it, and a
    /// badge in the ear. Left out, every part of the timer module would be
    /// unreachable — the whole feature would ship invisible, which is the
    /// same failure the clipboard had before this switcher existed.
    static let visible: [CreativeNotchCore.Tab] = [.shelf, .clipboard, .timer]

    let selected: CreativeNotchCore.Tab
    let onSelect: (CreativeNotchCore.Tab) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Self.visible, id: \.self) { tab in
                Button {
                    onSelect(tab)
                } label: {
                    Text(tab.title)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(tab == selected ? 0.95 : 0.5))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background {
                            RoundedRectangle(cornerRadius: 7)
                                .fill(.white.opacity(tab == selected ? 0.14 : 0))
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 8)
    }
}
