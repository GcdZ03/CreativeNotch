import Foundation
import Testing
@testable import CreativeNotchCore

// MARK: - Existence and order

@Test func theDefaultTabsAreTheUnconditionalOnesPlusPowerAndCamera() {
    #expect(TabVisibility.visible(enabled: .allEnabled, hasBattery: true)
            == [.shelf, .clipboard, .timer, .power, .camera])
    #expect(TabVisibility.visible(enabled: .allEnabled, hasBattery: false)
            == [.shelf, .clipboard, .timer, .camera])
}

/// Replaces `PanelTabBarTests.hidingThePowerTabLeavesTheOthersInPlace`, whose
/// `prefix` assertion assumed only *trailing* tabs are conditional. Now that
/// any tab can vanish, the honest invariant is that relative order survives
/// removal -- checked across all 16 combinations rather than by one example,
/// because a single case is mutation-blind.
@Test func relativeOrderIsPreservedUnderAnyRemoval() {
    let canonical: [Tab] = [.shelf, .clipboard, .timer, .power, .camera]
    for mask in 0..<32 {
        var preferences = Preferences.allEnabled
        preferences.shelf     = mask & 1 != 0
        preferences.clipboard = mask & 2 != 0
        preferences.timer     = mask & 4 != 0
        preferences.power     = mask & 8 != 0
        preferences.camera    = mask & 16 != 0

        let tabs = TabVisibility.visible(enabled: preferences, hasBattery: true)
        #expect(tabs == canonical.filter { tabs.contains($0) },
                "order changed for mask \(mask): \(tabs)")
        #expect(tabs.count == [preferences.shelf, preferences.clipboard,
                               preferences.timer, preferences.power,
                               preferences.camera].filter { $0 }.count)
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

/// The camera is appended last, like `.power`, so hiding it never reorders the
/// tabs that were already there.
@Test func theCameraTabIsAppendedRatherThanInserted() {
    var noCamera = Preferences.allEnabled
    noCamera.camera = false
    let without = TabVisibility.visible(enabled: noCamera, hasBattery: true)
    let with = TabVisibility.visible(enabled: .allEnabled, hasBattery: true)

    #expect(Array(with.dropLast()) == without)
    #expect(with.last == .camera)
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

/// A tab whose module is off always falls back -- the case that would
/// otherwise let a caller hold a selection no list contains.
@Test func aHiddenTabAlwaysFallsBack() {
    var noCamera = Preferences.allEnabled
    noCamera.camera = false
    #expect(TabVisibility.fallback(from: .camera, enabled: noCamera, hasBattery: true) == .shelf)
}
