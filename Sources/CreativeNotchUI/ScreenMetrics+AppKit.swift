import AppKit
import CreativeNotchCore

extension NSScreen {
    /// The screen "Show on" picks right now, by `DisplayChoice.screen(in:)`.
    ///
    /// Read fresh on every call rather than remembered: the list changes
    /// with the cables, and a remembered `NSScreen` for a display that has
    /// gone is a panel placed on nothing.
    @MainActor
    static func chosen(by choice: DisplayChoice) -> NSScreen? {
        let screens = NSScreen.screens
        let main = NSScreen.main
        let descriptors = screens.compactMap { screen in
            screen.displayID.map {
                ScreenDescriptor(id: $0, isBuiltIn: CGDisplayIsBuiltin($0) != 0, isMain: screen == main)
            }
        }
        guard let id = choice.screen(in: descriptors) else { return nil }
        return screens.first { $0.displayID == id }
    }

    /// The window server's number for this screen, the id the rule and
    /// `CGDisplayIsBuiltin` share.
    @MainActor
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// Snapshots this screen into the AppKit-free value type the core uses.
    @MainActor
    public var metrics: ScreenMetrics {
        ScreenMetrics(
            frame: frame,
            safeAreaTopInset: safeAreaInsets.top,
            auxiliaryTopLeftWidth: auxiliaryTopLeftArea?.width ?? 0,
            auxiliaryTopRightWidth: auxiliaryTopRightArea?.width ?? 0,
            menuBarHeight: menuBarHeight
        )
    }

    /// The height of the menu bar *on this screen*, measured rather than
    /// assumed.
    ///
    /// The obvious `NSApplication.shared.mainMenu?.menuBarHeight` is dead
    /// code here: an `.accessory` app with no nib never has a `mainMenu`,
    /// so it always fell through to a hardcoded 24 -- wrong on any display
    /// whose menu bar is not exactly that, and wrong per-screen by
    /// construction since it is a single app-wide value.
    ///
    /// `frame.maxY - visibleFrame.maxY` is the gap AppKit reserves at the
    /// *top* edge of this specific screen, which is the menu bar and
    /// nothing else -- the Dock only ever occupies the bottom, left, or
    /// right edge, so unlike `frame.height - visibleFrame.height` this
    /// needs no Dock correction. It is also genuinely per-screen, which
    /// `NSStatusBar.system.thickness` (one app-wide value) is not: with
    /// "Displays have separate Spaces" off, a secondary screen has no menu
    /// bar at all and correctly measures 0.
    ///
    /// Only the pill branch of `NotchGeometry.anchor` reads this; a real
    /// notch is positioned from `safeAreaTopInset` instead.
    @MainActor
    var menuBarHeight: CGFloat {
        max(0, frame.maxY - visibleFrame.maxY)
    }
}
