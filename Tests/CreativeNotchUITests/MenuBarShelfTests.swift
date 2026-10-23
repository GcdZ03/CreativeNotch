import AppKit
import Testing
@testable import CreativeNotchUI

@MainActor
struct MenuBarShelfTests {

    @Test func theClearItemReportsHowManyAreOnTheShelf() {
        var cleared = false
        let controller = MenuBarController(
            onShowPreferences: {},
            onClearShelf: { cleared = true },
            shelfCount: { 3 },
            onClearClipboard: {},
            clipboardCount: { 0 }
        )
        #expect(controller.clearShelfTitle() == "Clear Shelf (3)")
        controller.clearShelf()
        #expect(cleared)
    }

    @Test func anEmptyShelfSaysSo() {
        let controller = MenuBarController(
            onShowPreferences: {},
            onClearShelf: {},
            shelfCount: { 0 },
            onClearClipboard: {},
            clipboardCount: { 0 }
        )
        #expect(controller.clearShelfTitle() == "Shelf is empty")
    }

    /// Undo Clear Shelf is there only while a clear can still be undone,
    /// read when the menu opens like the counts.
    @Test func undoClearShelfShowsOnlyWhileItCanBeUndone() {
        var canUndo = false
        var undone = 0
        let controller = MenuBarController(
            onShowPreferences: {},
            onClearShelf: {},
            shelfCount: { 0 },
            onClearClipboard: {},
            clipboardCount: { 0 },
            onUndoClearShelf: { undone += 1 },
            canUndoClearShelf: { canUndo }
        )
        #expect(controller.showsUndoClearShelf == false)
        canUndo = true
        #expect(controller.showsUndoClearShelf)
        controller.undoClearShelf()
        #expect(undone == 1)
    }

    @Test func oneItemIsNotPluralised() {
        let controller = MenuBarController(
            onShowPreferences: {},
            onClearShelf: {},
            shelfCount: { 1 },
            onClearClipboard: {},
            clipboardCount: { 0 }
        )
        #expect(controller.clearShelfTitle() == "Clear Shelf (1)")
    }
}
