import Foundation

/// Which tabs exist, and in what order.
///
/// Moved down from `PanelTabBar` because it is pure and worth testing, which is
/// where `CONTRIBUTING.md` says such logic belongs. It remains the **single
/// source of tab existence and order** — not the enum's declaration order, not
/// `CaseIterable`.
///
/// It became a function when `.power` arrived as the first hardware-conditional
/// tab. Preferences is the second axis, and the first that can turn a tab off
/// *while the panel is open*.
///
/// **Hardware availability and user preference stay two separate arguments.**
/// `hasBattery` answers "can this machine do it", which is not "does the user
/// want it". They are ANDed here, at the point of use; neither may overwrite
/// the other, because `hasBattery` is rewritten at runtime on every power
/// notification and would clobber a preference folded into it.
public enum TabVisibility {
    /// `.power` is appended rather than inserted, so hiding it never reorders
    /// the tabs that were already there. `.hud` is never offered at all: it
    /// owns no panel content, and a tab that opens onto a placeholder is worse
    /// than no tab.
    public static func visible(enabled: Preferences, hasBattery: Bool) -> [Tab] {
        var tabs: [Tab] = []
        if enabled.shelf { tabs.append(.shelf) }
        if enabled.clipboard { tabs.append(.clipboard) }
        if enabled.timer { tabs.append(.timer) }
        if enabled.power, hasBattery { tabs.append(.power) }
        return tabs
    }

    /// The tab to show when the one that was selected has just disappeared.
    ///
    /// `nil` means there is nothing left to show and the panel should close.
    /// An empty list is a legal state, not a trap: the preferences window is
    /// reached from the menu bar, so a person who has switched off every
    /// tab-bearing module can still switch one back on.
    public static func fallback(
        from selected: Tab,
        enabled: Preferences,
        hasBattery: Bool
    ) -> Tab? {
        let tabs = visible(enabled: enabled, hasBattery: hasBattery)
        if tabs.contains(selected) { return selected }
        return tabs.first
    }
}
