import AppKit

/// A non-activating, borderless panel pinned above the menu bar.
///
/// `.fullScreenAuxiliary` is deliberately absent from `collectionBehavior`.
/// That single omission is what hides the panel entirely over fullscreen
/// apps — no frontmost-window detection, no edge cases.
public final class NotchPanel: NSPanel {

    /// Key, but never main.
    ///
    /// These are not the same switch, and the difference is the whole
    /// reason typing in the panel is possible without the panel becoming a
    /// nuisance. `.nonactivatingPanel` means becoming key does **not**
    /// activate the app: the frontmost application stays frontmost and
    /// keeps its menu bar. What it does lose is its insertion point, for as
    /// long as the panel holds focus.
    ///
    /// So this is `true` only because one control needs it — the timer's
    /// custom-minutes field. `AppDelegate` makes the panel key only while
    /// that tab is open and hands focus straight back on close; every other
    /// presentation still never touches it. See `syncKeyWindow`.
    ///
    /// `canBecomeMain` stays `false`: main is for a document window that
    /// owns the app's menus, which this is not.
    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }

    public init(contentRect: NSRect) {
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
