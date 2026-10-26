import CoreGraphics

/// Where the frontmost app's frontmost window is, for "Show on: the
/// focused window" (2026-10-26).
///
/// Following focus used to read `NSScreen.main`, and when an app comes
/// forward that still names the screen of the app before it: macOS updates
/// it a moment after `didActivateApplication`. Measured on a three-display
/// desk, every switch put the notch on the screen just left. The window
/// server's list is already in the new order when the notification arrives,
/// so the window is read from there instead.
///
/// AppKit-free like `ScreenMetrics`: the UI target reads the window list and
/// hands it in.
public enum FocusedWindow {

    /// One entry of the window server's list, `CGWindowListCopyWindowInfo`.
    public struct Entry: Equatable, Sendable {
        public var pid: Int32
        /// The window level; 0 is an ordinary window. Menus, panels, the
        /// Dock and this app's own notch sit above it.
        public var layer: Int
        public var alpha: Double
        /// In the window server's global space: top-left origin, y down.
        public var bounds: CGRect

        public init(pid: Int32, layer: Int, alpha: Double = 1, bounds: CGRect) {
            self.pid = pid
            self.layer = layer
            self.alpha = alpha
            self.bounds = bounds
        }
    }

    /// The frame of `pid`'s frontmost ordinary window, in AppKit's global
    /// space (bottom-left origin, as `NSScreen.frame` is), or `nil` when it
    /// has none on screen -- an accessory app, or Finder showing only the
    /// desktop.
    ///
    /// `windows` is front to back, as the window server lists them, so the
    /// first of `pid`'s is the one it is focused on. Only ordinary windows
    /// count: a menu or a floating panel is not where the user is working,
    /// and an invisible or empty one is not anywhere.
    ///
    /// `primaryHeight` is the height of the screen at AppKit's origin -- the
    /// one the two spaces are flipped about.
    public static func frame(of pid: Int32, in windows: [Entry], primaryHeight: CGFloat) -> CGRect? {
        guard let window = windows.first(where: {
            $0.pid == pid && $0.layer == 0 && $0.alpha > 0 && !$0.bounds.isEmpty
        }) else { return nil }
        let b = window.bounds
        return CGRect(x: b.minX, y: primaryHeight - b.maxY, width: b.width, height: b.height)
    }
}
