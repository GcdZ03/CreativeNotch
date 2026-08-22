import AppKit
import Testing
@testable import CreativeNotchUI

@MainActor
struct MenuBarShelfTests {

    @Test func theClearItemReportsHowManyAreOnTheShelf() {
        var cleared = false
        let controller = MenuBarController(
            onShowOnboarding: {},
            onClearShelf: { cleared = true },
            shelfCount: { 3 }
        )
        #expect(controller.clearShelfTitle() == "Clear Shelf (3)")
        controller.clearShelf()
        #expect(cleared)
    }

    @Test func anEmptyShelfSaysSo() {
        let controller = MenuBarController(
            onShowOnboarding: {},
            onClearShelf: {},
            shelfCount: { 0 }
        )
        #expect(controller.clearShelfTitle() == "Shelf is empty")
    }

    @Test func oneItemIsNotPluralised() {
        let controller = MenuBarController(
            onShowOnboarding: {},
            onClearShelf: {},
            shelfCount: { 1 }
        )
        #expect(controller.clearShelfTitle() == "Clear Shelf (1)")
    }
}
