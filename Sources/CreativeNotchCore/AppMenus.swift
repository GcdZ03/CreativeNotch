import CoreGraphics

/// How far the frontmost app's menus reach along the menu bar, for "Keep
/// clear of app menus" (2026-10-26).
///
/// On a display with no notch, macOS lays an app's menus out from the left
/// edge knowing nothing of the pill, so on a narrow display a long menu bar
/// ran under it. The answer here is what `NotchGeometry.anchor(for:menusEnd:)`
/// moves the pill clear of.
///
/// AppKit-free like `ScreenMetrics`: the UI target reads the frames through
/// Accessibility and hands them in.
public enum AppMenus {
    /// How far from its display's left edge the menus reach: the leftmost
    /// item's offset from that edge, plus the width of every item.
    ///
    /// The widths are summed rather than the last item's edge read, because
    /// the menus are measured on whichever display has the active menu bar.
    /// On a notched display, menus that do not fit left of the camera carry
    /// on right of it, and the last edge there would count the housing -- a
    /// gap a display without a notch, where the pill is, does not have.
    ///
    /// Frames and screens are in the window server's global space, top-left
    /// origin, as Accessibility reports them; only the leftmost item's
    /// display matters, found by the item's centre. `nil` with no items, or
    /// with the leftmost on no known display -- no answer, rather than a
    /// guess that would move the pill.
    public static func end(itemFrames: [CGRect], screens: [CGRect]) -> CGFloat? {
        guard let first = itemFrames.min(by: { $0.minX < $1.minX }),
              let screen = screens.first(where: { $0.contains(CGPoint(x: first.midX, y: first.midY)) })
        else { return nil }
        return first.minX - screen.minX + itemFrames.reduce(0) { $0 + max($1.width, 0) }
    }
}
