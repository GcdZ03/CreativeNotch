import AppKit
import CreativeNotchCore

extension NSScreen {
    /// The screen "Show on" picks right now, by
    /// `DisplayChoice.screen(in:focusedWindow:)`.
    ///
    /// Read fresh on every call rather than remembered: the list changes
    /// with the cables, and a remembered `NSScreen` for a display that has
    /// gone is a panel placed on nothing. Following focus, the focused
    /// window is read too, so a screen change lands where a switch would
    /// (2026-10-29); pinned, the window list is not read.
    @MainActor
    static func chosen(by choice: DisplayChoice) -> NSScreen? {
        let window = choice.followsActivation ? focusedWindowFrame : nil
        return picked { choice.screen(in: $0, focusedWindow: window) }
    }

    /// The screen a change of focus moves the panel to, by
    /// `DisplayChoice.screenOnFocusChange`: `nil` when pinned, or when the
    /// frontmost app has no window to go by, so the panel stays where it is.
    ///
    /// Pinned, the window list is not even read.
    @MainActor
    static func chosenOnFocusChange(by choice: DisplayChoice) -> NSScreen? {
        guard choice.followsActivation else { return nil }
        let window = focusedWindowFrame
        return picked { choice.screenOnFocusChange(in: $0, focusedWindow: window) }
    }

    /// The frontmost app's frontmost window, in AppKit's global space, read
    /// from the window server's list (`FocusedWindow.frame`). One read is a
    /// few milliseconds and asks for no permission: bounds, owners and levels
    /// are readable without Screen Recording, only titles are not.
    @MainActor
    private static var focusedWindowFrame: CGRect? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let primary = screens.first,
              let list = CGWindowListCopyWindowInfo(
                  [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
              ) as? [[String: Any]]
        else { return nil }
        let windows = list.compactMap { info -> FocusedWindow.Entry? in
            guard let owner = info[kCGWindowOwnerPID as String] as? Int32,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo)
            else { return nil }
            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
            return FocusedWindow.Entry(pid: owner, layer: layer, alpha: alpha, bounds: bounds)
        }
        return FocusedWindow.frame(of: pid, in: windows, primaryHeight: primary.frame.maxY)
    }

    @MainActor
    private static func picked(by rule: ([ScreenDescriptor]) -> CGDirectDisplayID?) -> NSScreen? {
        guard let id = rule(descriptors) else { return nil }
        return screens.first { $0.displayID == id }
    }

    /// Every connected screen as the rule and the "Show on" menu see it,
    /// read fresh -- the menu's list and the placement come from the same
    /// reading, so a display Settings offers is one the rule can find.
    @MainActor
    static var descriptors: [ScreenDescriptor] {
        let main = NSScreen.main
        return screens.compactMap { screen in
            screen.displayID.map {
                ScreenDescriptor(
                    id: $0, isBuiltIn: CGDisplayIsBuiltin($0) != 0, isMain: screen == main,
                    uuid: uuid(of: $0), name: screen.localizedName, frame: screen.frame
                )
            }
        }
    }

    /// The display's persistent UUID, uppercase as `CFUUIDCreateString`
    /// spells it, or `nil` if the system has none for it. Unlike the
    /// display id, it is the same for the same display after a reboot or
    /// a reconnection, which is what a pin has to survive.
    private static func uuid(of id: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
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
