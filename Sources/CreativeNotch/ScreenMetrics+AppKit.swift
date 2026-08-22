import AppKit
import CreativeNotchCore

extension NSScreen {
    /// Snapshots this screen into the AppKit-free value type the core uses.
    @MainActor
    var metrics: ScreenMetrics {
        ScreenMetrics(
            frame: frame,
            safeAreaTopInset: safeAreaInsets.top,
            auxiliaryTopLeftWidth: auxiliaryTopLeftArea?.width ?? 0,
            auxiliaryTopRightWidth: auxiliaryTopRightArea?.width ?? 0,
            menuBarHeight: NSApplication.shared.mainMenu?.menuBarHeight ?? 24
        )
    }
}
