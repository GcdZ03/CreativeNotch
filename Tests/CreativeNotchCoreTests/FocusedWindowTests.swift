import CoreGraphics
import Testing
@testable import CreativeNotchCore

/// Reading the focused window out of the window server's list (2026-10-26):
/// which entry is it, and where is it in AppKit's space.
///
/// The list is front to back, in the window server's top-left space; the
/// real one cannot be arranged from a test, so these are plain entries.
struct FocusedWindowTests {

    private typealias Entry = FocusedWindow.Entry

    private let chrome: Int32 = 475
    private let warp: Int32 = 512
    /// The built-in display's height: the two spaces flip about it.
    private let primaryHeight: CGFloat = 982

    /// The first of the app's ordinary windows is the one it is focused on,
    /// whatever other apps' windows are above it.
    @Test func theFrontmostOfTheAppsWindowsIsTheFocusedOne() {
        let windows = [
            Entry(pid: warp, layer: 0, bounds: CGRect(x: 1512, y: -977, width: 1080, height: 1890)),
            Entry(pid: chrome, layer: 0, bounds: CGRect(x: -408, y: -1050, width: 1920, height: 1050)),
            Entry(pid: chrome, layer: 0, bounds: CGRect(x: 0, y: 33, width: 1512, height: 894)),
        ]
        let frame = FocusedWindow.frame(of: chrome, in: windows, primaryHeight: primaryHeight)
        // Flipped: the window's bottom edge, y 0 in the window server, is
        // the top of the built-in display, AppKit's 982.
        #expect(frame == CGRect(x: -408, y: 982, width: 1920, height: 1050))
    }

    /// A window on the built-in display, below its 33pt menu bar.
    @Test func aWindowIsFlippedIntoAppKitsSpace() {
        let windows = [Entry(pid: chrome, layer: 0, bounds: CGRect(x: 0, y: 33, width: 1512, height: 894))]
        let frame = FocusedWindow.frame(of: chrome, in: windows, primaryHeight: primaryHeight)
        #expect(frame == CGRect(x: 0, y: 55, width: 1512, height: 894))
    }

    /// Menus, floating panels and invisible or empty windows are not where
    /// the user is working, even when they are the app's frontmost.
    @Test func onlyOrdinaryVisibleWindowsCount() {
        let windows = [
            Entry(pid: chrome, layer: 101, bounds: CGRect(x: 1600, y: -900, width: 200, height: 300)),
            Entry(pid: chrome, layer: 3, bounds: CGRect(x: 1600, y: -900, width: 400, height: 300)),
            Entry(pid: chrome, layer: 0, alpha: 0, bounds: CGRect(x: 1600, y: -900, width: 400, height: 300)),
            Entry(pid: chrome, layer: 0, bounds: CGRect(x: 1600, y: -900, width: 0, height: 0)),
            Entry(pid: chrome, layer: 0, bounds: CGRect(x: 0, y: 33, width: 1512, height: 894)),
        ]
        let frame = FocusedWindow.frame(of: chrome, in: windows, primaryHeight: primaryHeight)
        #expect(frame == CGRect(x: 0, y: 55, width: 1512, height: 894))
    }

    /// An app with no window on screen -- an accessory app, or Finder with
    /// only the desktop -- has no focused window.
    @Test func anAppWithNoWindowHasNone() {
        let windows = [Entry(pid: warp, layer: 0, bounds: CGRect(x: 1512, y: -977, width: 1080, height: 1890))]
        #expect(FocusedWindow.frame(of: chrome, in: windows, primaryHeight: primaryHeight) == nil)
        #expect(FocusedWindow.frame(of: chrome, in: [], primaryHeight: primaryHeight) == nil)
    }
}
