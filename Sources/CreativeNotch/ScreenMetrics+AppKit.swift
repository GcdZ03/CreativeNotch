import AppKit
import CreativeNotchCore

/// Disambiguates `CreativeNotchCore.Anchor` from `SwiftUI.Anchor` for files
/// that import both. Declared in a file with no SwiftUI import so `Anchor`
/// here is unambiguous; `CreativeNotchCore.Anchor` itself can't be spelled
/// out in a SwiftUI-importing file because `CreativeNotchCore` is *also*
/// the name of a public enum inside the module (`Version.swift`), which
/// wins qualified-name lookup over the module itself.
typealias CoreAnchor = Anchor

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
