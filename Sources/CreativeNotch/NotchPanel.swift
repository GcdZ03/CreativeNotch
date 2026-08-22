import AppKit

/// A non-activating, borderless panel pinned above the menu bar.
///
/// `.fullScreenAuxiliary` is deliberately absent from `collectionBehavior`.
/// That single omission is what hides the panel entirely over fullscreen
/// apps — no frontmost-window detection, no edge cases.
final class NotchPanel: NSPanel {

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    }
}
