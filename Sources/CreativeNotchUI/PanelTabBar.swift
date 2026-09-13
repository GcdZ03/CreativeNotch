import SwiftUI
import CreativeNotchCore

public extension CreativeNotchCore.Tab {
    var title: String {
        switch self {
        case .shelf:     return "Shelf"
        case .clipboard: return "Clipboard"
        case .hud:       return "HUD"
        case .power:     return "Power"
        case .timer:     return "Timer"
        case .camera:    return "Camera"
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
    /// `.hud` stays in the `Tab` enum because two exhaustive switches --
    /// `title` and `openContent` -- would stop compiling without it. It is
    /// never offered as a tab: HUD history is not built, and a tab that opens
    /// onto a placeholder is worse than no tab.
    ///
    /// This comment used to claim `PeekArbiter` and `AppDelegate` reference
    /// the case. They do not -- those are `PeekContent.hud`, a different
    /// type -- and the wrong reason survived because nothing tested it.
    ///
    /// `.timer` is unconditional: the tab has real content
    /// (`TimerTabView`), a real controller behind it, and a badge in the
    /// ear, and none of that depends on hardware. Left out, every part of
    /// the timer module would be unreachable and the whole feature would
    /// ship invisible.
    ///
    /// It is placed *before* the conditional `.power` append so that the
    /// timer's position does not move between a MacBook and a desktop, and
    /// so `.power` stays last exactly as its own note below intends.
    ///
    /// **Delegates to `TabVisibility` rather than keeping its own list.** It
    /// kept one until this was caught by running the app: the switchboard
    /// computed the right tabs and retargeted the selection, while this view
    /// went on drawing all four regardless of any preference. Every test
    /// passed, because they exercised the Core function and the switchboard --
    /// never the view's own answer.
    ///
    /// That is the same shape as the `PassthroughContainer` trap recorded in
    /// ARCHITECTURE.md: each piece correct, the assembly wrong. One rule,
    /// spelled once, is the only fix that stays fixed.
    static func visible(
        enabled: Preferences,
        hasBattery: Bool
    ) -> [CreativeNotchCore.Tab] {
        TabVisibility.visible(enabled: enabled, hasBattery: hasBattery)
    }

    let selected: CreativeNotchCore.Tab
    let enabled: Preferences
    let hasBattery: Bool
    let onSelect: (CreativeNotchCore.Tab) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Self.visible(enabled: enabled, hasBattery: hasBattery), id: \.self) { tab in
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
