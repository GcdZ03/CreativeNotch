import Foundation
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// The switcher that makes the clipboard reachable at all.
@MainActor
struct PanelTabBarTests {

    /// Every tab in the list owns real panel content — a tab that opens onto
    /// a placeholder is worse than no tab.
    ///
    /// `.timer` is worth calling out: `TimerTabView`
    /// is real content with a real controller behind it. Left out, the
    /// whole timer module would be unreachable from the UI — every task in
    /// it dead code — and nothing else in the suite would notice. That is
    /// why this array is pinned by literal here rather than merely
    /// spot-checked with `contains`.
    @Test func onlyTabsWithContentAreShown() {
        #expect(PanelTabBar.visible(enabled: .allEnabled, hasBattery: true)
                == [.shelf, .clipboard, .timer, .power, .camera])
    }

    // MARK: - The view must not keep its own list

    /// **The test this file was missing, and the bug it would have caught.**
    ///
    /// `PanelTabBar` kept a hardcoded list that ignored preferences entirely.
    /// The switchboard computed the right tabs and retargeted the selection,
    /// and every test passed -- because they exercised `TabVisibility` and the
    /// switchboard, never the view's own answer. Switching a module off simply
    /// never removed its tab, and it took running the app to see it.
    ///
    /// Same shape as the `PassthroughContainer` trap: each piece correct, the
    /// assembly wrong.
    @Test func theTabBarAgreesWithTheCoreRuleForEveryCombination() {
        for mask in 0..<32 {
            var preferences = Preferences.allEnabled
            preferences.shelf     = mask & 1 != 0
            preferences.clipboard = mask & 2 != 0
            preferences.timer     = mask & 4 != 0
            preferences.power     = mask & 8 != 0
            preferences.camera    = mask & 16 != 0

            for hasBattery in [true, false] {
                #expect(
                    PanelTabBar.visible(enabled: preferences, hasBattery: hasBattery)
                    == TabVisibility.visible(enabled: preferences, hasBattery: hasBattery),
                    "the view disagreed with the rule at mask \(mask), hasBattery \(hasBattery)"
                )
            }
        }
    }

    /// **The body is pinned by a source scan, because nothing else can reach
    /// it.** A SwiftUI body is not callable from a test, so a `visible(...)`
    /// that honours preferences correctly and a body that calls it with
    /// `.allEnabled` would both pass every assertion in this file -- which is
    /// the same bug one level down from the one this suite just caught.
    ///
    /// The shape is `ClipboardStoreTests.theStoreNeverTouchesTheFileSystem`
    /// and `AppDelegateTests.theLaunchPathStartsSubsystemsOnlyThroughTheOne
    /// Method`: where behaviour is unreachable, scan the source and say so.
    @Test func theBodyRendersTheListItWasGiven() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/CreativeNotchUI/PanelTabBar.swift")
        let text = try String(contentsOf: source, encoding: .utf8)

        #expect(
            text.contains("ForEach(Self.visible(enabled: enabled, hasBattery: hasBattery)"),
            "the body no longer renders the list built from its own parameters"
        )
        // And it must not reach past its parameters to a fixed answer.
        #expect(text.contains(".allEnabled") == false,
                "the body hardcodes a preferences value instead of using the one passed in")
    }

    /// Stated separately, because the combination sweep above would still pass
    /// if both sides were wrong in the same way.
    @Test func switchingAModuleOffRemovesItsTabFromTheBar() {
        var noClipboard = Preferences.allEnabled
        noClipboard.clipboard = false

        let tabs = PanelTabBar.visible(enabled: noClipboard, hasBattery: true)

        #expect(tabs.contains(.clipboard) == false)
        #expect(tabs == [.shelf, .timer, .power, .camera])
    }

    /// Three of the four facts on the power tab are meaningless without a
    /// battery, so it is hidden on a Mac mini.
    @Test func thePowerTabIsHiddenWithoutABattery() {
        #expect(PanelTabBar.visible(enabled: .allEnabled, hasBattery: false)
                == [.shelf, .clipboard, .timer, .camera])
        #expect(PanelTabBar.visible(enabled: .allEnabled, hasBattery: false).contains(.power) == false)
    }

    /// Hiding the tab must not reorder the ones that remain — the two
    /// existing tabs sit where they always did, whatever the machine is.
    @Test func hidingThePowerTabLeavesTheOthersInPlace() {
        let with = PanelTabBar.visible(enabled: .allEnabled, hasBattery: true)
        let without = PanelTabBar.visible(enabled: .allEnabled, hasBattery: false)

        // Relative order survives removal. The old `prefix` form assumed only
        // trailing tabs are conditional, which stopped being true once any tab
        // could vanish.
        #expect(without == with.filter { without.contains($0) })
    }

    @Test func everyVisibleTabHasATitle() {
        for tab in PanelTabBar.visible(enabled: .allEnabled, hasBattery: true) {
            #expect(tab.title.isEmpty == false)
        }
        #expect(Tab.shelf.title == "Shelf")
        #expect(Tab.clipboard.title == "Clipboard")
        #expect(Tab.timer.title == "Timer")
        #expect(Tab.power.title == "Power")
        #expect(Tab.camera.title == "Camera")
    }

    /// A machine with no battery must not be left promising a tab it
    /// cannot fill, so the conservative shape is the default.
    @Test func aFreshStateAssumesNoBattery() {
        #expect(AppState().hasBattery == false)
    }

    // MARK: - Last-tab memory

    @Test func aFreshStateRemembersTheShelf() {
        #expect(AppState().lastOpenTab == .shelf)
    }

    @Test func openingATabRemembersIt() {
        let state = AppState()
        state.transition(to: .open(.clipboard))

        #expect(state.lastOpenTab == .clipboard)
    }

    /// Closing must not forget. Reopening the panel returns to the tab the
    /// user was last on, which is the entire point of remembering.
    @Test func closingKeepsTheRememberedTab() {
        let state = AppState()
        state.transition(to: .open(.clipboard))
        state.transition(to: .closed)

        #expect(state.lastOpenTab == .clipboard)
    }

    /// A peek is not a tab. Letting one touch this would reset the user's
    /// tab out from under them.
    @Test func peeksDoNotDisturbTheRememberedTab() {
        let state = AppState()
        state.transition(to: .open(.clipboard))
        state.transition(to: .peek(.power(.unplugged(level: 50))))

        #expect(state.lastOpenTab == .clipboard)
    }

    @Test func receivingADropDoesNotDisturbTheRememberedTab() {
        let state = AppState()
        state.transition(to: .open(.clipboard))
        state.transition(to: .receiving)

        #expect(state.lastOpenTab == .clipboard)
    }

    @Test func switchingTabsUpdatesTheMemory() {
        let state = AppState()
        state.transition(to: .open(.clipboard))
        state.transition(to: .open(.shelf))

        #expect(state.lastOpenTab == .shelf)
    }
}
