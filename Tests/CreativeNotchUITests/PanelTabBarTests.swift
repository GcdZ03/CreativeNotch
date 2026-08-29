import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// The switcher that makes the clipboard reachable at all.
@MainActor
struct PanelTabBarTests {

    /// `.hud` stays in the `Tab` enum — `PeekArbiter` and `AppDelegate`
    /// both reference it — but HUD history does not exist, and a tab that
    /// opens onto a placeholder is worse than no tab.
    @Test func onlyTabsWithContentAreShown() {
        #expect(PanelTabBar.visible == [.shelf, .clipboard])
        #expect(PanelTabBar.visible.contains(.hud) == false)
    }

    @Test func everyVisibleTabHasATitle() {
        for tab in PanelTabBar.visible {
            #expect(tab.title.isEmpty == false)
        }
        #expect(Tab.shelf.title == "Shelf")
        #expect(Tab.clipboard.title == "Clipboard")
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

    /// A peek is not a tab. HUD peeks fire constantly, and letting one
    /// touch this would reset the user's tab out from under them.
    @Test func peeksDoNotDisturbTheRememberedTab() {
        let state = AppState()
        state.transition(to: .open(.clipboard))
        state.transition(to: .peek(.hud(HUDEvent(kind: .volume(0.5)))))

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
