import Foundation
import Testing
@testable import CreativeNotchCore

// MARK: - Existence and order

@Test func theDefaultTabsAreTheThreeUnconditionalOnesPlusPower() {
    #expect(TabVisibility.visible(enabled: .allEnabled, hasBattery: true)
            == [.shelf, .clipboard, .timer, .power])
    #expect(TabVisibility.visible(enabled: .allEnabled, hasBattery: false)
            == [.shelf, .clipboard, .timer])
}

/// `.hud` owns no panel content. It is never offered however the preferences
/// are set -- a tab that opens onto a placeholder is worse than no tab.
@Test func theHUDIsNeverATab() {
    for hasBattery in [true, false] {
        var everything = Preferences.allEnabled
        everything.hud = true
        #expect(!TabVisibility.visible(enabled: everything, hasBattery: hasBattery).contains(.hud))
        everything.hud = false
        #expect(!TabVisibility.visible(enabled: everything, hasBattery: hasBattery).contains(.hud))
    }
}

/// Replaces `PanelTabBarTests.hidingThePowerTabLeavesTheOthersInPlace`, whose
/// `prefix` assertion assumed only *trailing* tabs are conditional. Now that
/// any tab can vanish, the honest invariant is that relative order survives
/// removal -- checked across all 16 combinations rather than by one example,
/// because a single case is mutation-blind.
@Test func relativeOrderIsPreservedUnderAnyRemoval() {
    let canonical: [Tab] = [.shelf, .clipboard, .timer, .power]
    for mask in 0..<16 {
        var preferences = Preferences.allEnabled
        preferences.shelf     = mask & 1 != 0
        preferences.clipboard = mask & 2 != 0
        preferences.timer     = mask & 4 != 0
        preferences.power     = mask & 8 != 0

        let tabs = TabVisibility.visible(enabled: preferences, hasBattery: true)
        #expect(tabs == canonical.filter { tabs.contains($0) },
                "order changed for mask \(mask): \(tabs)")
        #expect(tabs.count == [preferences.shelf, preferences.clipboard,
                               preferences.timer, preferences.power].filter { $0 }.count)
    }
}

/// Hardware and preference are two separate axes and must be ANDed, never
/// conflated: `hasBattery` is rewritten at runtime on every power notification
/// and would clobber a preference folded into it.
@Test func thePowerTabNeedsBothABatteryAndThePreference() {
    var off = Preferences.allEnabled
    off.power = false
    #expect(!TabVisibility.visible(enabled: off, hasBattery: true).contains(.power))
    #expect(!TabVisibility.visible(enabled: .allEnabled, hasBattery: false).contains(.power))
    #expect(TabVisibility.visible(enabled: .allEnabled, hasBattery: true).contains(.power))
}

@Test func everyModuleBeingOffLeavesNoTabsAtAll() {
    var nothing = Preferences.allEnabled
    for module in ModuleID.allCases { nothing[module] = false }
    #expect(TabVisibility.visible(enabled: nothing, hasBattery: true).isEmpty)
}

// MARK: - The fallback

@Test func aStillVisibleTabIsLeftSelected() {
    #expect(TabVisibility.fallback(from: .clipboard, enabled: .allEnabled, hasBattery: true) == .clipboard)
}

@Test func aTabThatHasJustVanishedFallsBackToTheFirstOneLeft() {
    var noShelf = Preferences.allEnabled
    noShelf.shelf = false
    #expect(TabVisibility.fallback(from: .shelf, enabled: noShelf, hasBattery: true) == .clipboard)

    var onlyTimer = Preferences.allEnabled
    onlyTimer.shelf = false
    onlyTimer.clipboard = false
    onlyTimer.power = false
    #expect(TabVisibility.fallback(from: .shelf, enabled: onlyTimer, hasBattery: true) == .timer)
}

/// An empty list is a legal state rather than a trap: the preferences window is
/// reached from the menu bar, so everything being off is recoverable.
@Test func nothingLeftToShowMeansNoTab() {
    var nothing = Preferences.allEnabled
    for module in ModuleID.allCases { nothing[module] = false }
    #expect(TabVisibility.fallback(from: .shelf, enabled: nothing, hasBattery: true) == nil)
}

/// `.hud` is never visible, so asking for it always falls back -- the case that
/// would otherwise let a caller hold a selection no list contains.
@Test func theHUDAlwaysFallsBack() {
    #expect(TabVisibility.fallback(from: .hud, enabled: .allEnabled, hasBattery: true) == .shelf)
}
