import SwiftUI
import CreativeNotchCore

public extension CreativeNotchCore.Tab {
    var title: String {
        switch self {
        case .shelf:     return "Shelf"
        case .clipboard: return "Clipboard"
        case .hud:       return "HUD"
        case .power:     return "Power"
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
    /// A function rather than the `static let` this used to be, because
    /// `.power` is the first tab whose existence depends on the hardware:
    /// three of its four facts are meaningless on a Mac with no internal
    /// battery, so the same rule that hides `.hud` hides it there. Low
    /// Power Mode does exist on a desktop, which is the argument for
    /// showing the tab everywhere with the battery rows blanked — but one
    /// live row out of four is a placeholder tab wearing a different hat.
    ///
    /// `.power` is appended rather than inserted, so hiding it never
    /// reorders the tabs that were already there.
    static func visible(hasBattery: Bool) -> [CreativeNotchCore.Tab] {
        var tabs: [CreativeNotchCore.Tab] = [.shelf, .clipboard]
        if hasBattery { tabs.append(.power) }
        return tabs
    }

    let selected: CreativeNotchCore.Tab
    let hasBattery: Bool
    let onSelect: (CreativeNotchCore.Tab) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Self.visible(hasBattery: hasBattery), id: \.self) { tab in
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
