import CoreGraphics
import Testing
@testable import CreativeNotchCore

/// "Keep clear of app menus" (2026-10-26): how far the frontmost app's menus
/// reach, from the frames Accessibility reports for its menu-bar items.
///
/// Frames and screens are in the window server's global space, top-left
/// origin, which is what Accessibility reports.
struct AppMenusTests {

    private let external = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    /// Apple menu, then the app's menus, side by side from the left edge.
    private func items(from x: CGFloat, widths: [CGFloat], y: CGFloat = 0) -> [CGRect] {
        var left = x
        return widths.map { width in
            defer { left += width }
            return CGRect(x: left, y: y, width: width, height: 30)
        }
    }

    @Test func theMenusEndWhereTheLastOneDoes() {
        let menus = items(from: 10, widths: [30, 80, 40, 50])
        #expect(AppMenus.end(itemFrames: menus, screens: [external]) == 210)
    }

    /// Measured from the display's own left edge, so the same menus give the
    /// same answer on a display placed anywhere in the arrangement.
    @Test func theEndIsMeasuredFromTheDisplaysLeftEdge() {
        let left = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
        let menus = items(from: -1910, widths: [30, 80, 40, 50], y: -200)
        #expect(AppMenus.end(itemFrames: menus, screens: [external, left]) == 210)
    }

    /// Reported in any order, the menus still end where the widths add up to.
    @Test func theOrderTheyAreReportedInDoesNotMatter() {
        let menus = items(from: 10, widths: [30, 80, 40, 50])
        #expect(AppMenus.end(itemFrames: menus.reversed(), screens: [external]) == 210)
    }

    /// On a notched display, menus that do not fit left of the camera carry on
    /// right of it. Measured there, the gap is the housing, which a display
    /// without a notch does not have: the widths are what the menus take.
    @Test func aGapForANotchIsNotCounted() {
        let builtIn = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let left = items(from: 10, widths: [30, 200, 300])
        let right = items(from: 860, widths: [100])
        #expect(AppMenus.end(itemFrames: left + right, screens: [builtIn]) == 640)
    }

    /// A menu-bar item the app hides is reported with no width; it takes no
    /// room, so it adds none.
    @Test func aZeroWidthItemAddsNothing() {
        let menus = items(from: 10, widths: [30, 80, 0, 50])
        #expect(AppMenus.end(itemFrames: menus, screens: [external]) == 170)
    }

    /// No menu bar, or menus on no known display: nothing to say, rather than
    /// a guess that would move the pill.
    @Test func noItemsOrNoDisplayIsNoAnswer() {
        #expect(AppMenus.end(itemFrames: [], screens: [external]) == nil)
        #expect(AppMenus.end(itemFrames: items(from: 10, widths: [30]), screens: []) == nil)
        let elsewhere = items(from: 5000, widths: [30], y: 5000)
        #expect(AppMenus.end(itemFrames: elsewhere, screens: [external]) == nil)
    }
}
