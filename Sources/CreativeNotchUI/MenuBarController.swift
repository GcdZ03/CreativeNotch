import AppKit

/// The status item, and the way to the settings window.
///
/// It used to say it was "the only settings surface", on the grounds that a
/// four-module personal tool does not need a preferences window. Ten modules
/// later it does. The panel's header has a gear that opens it too, but this
/// item is the one that survives every tab-bearing module being switched off
/// -- then the panel has nowhere to open, and the menu bar is the way in. That
/// is what makes an empty tab list a legal state rather than a trap.
///
/// `NSObject` (not a plain `final class`) because target-action —
/// `settings.target = self` / `#selector(openPreferences)` — requires it; a
/// plain Swift class has no Objective-C runtime identity for the selector to
/// resolve against.
@MainActor
public final class MenuBarController: NSObject {

    private var item: NSStatusItem?
    private(set) var settingsItem: NSMenuItem?
    private var clearShelfItem: NSMenuItem?
    private var undoClearShelfItem: NSMenuItem?
    private var clearClipboardItem: NSMenuItem?

    private let onShowPreferences: () -> Void
    private let onClearShelf: () -> Void
    private let shelfCount: () -> Int
    private let onClearClipboard: () -> Void
    private let clipboardCount: () -> Int
    private let onUndoClearShelf: () -> Void
    private let canUndoClearShelf: () -> Bool
    private let onShowWelcome: () -> Void

    /// The undo pair defaults to "never offered", so a caller with no shelf
    /// behind it need not spell it out.
    public init(
        onShowPreferences: @escaping () -> Void,
        onClearShelf: @escaping () -> Void,
        shelfCount: @escaping () -> Int,
        onClearClipboard: @escaping () -> Void,
        clipboardCount: @escaping () -> Int,
        onUndoClearShelf: @escaping () -> Void = {},
        canUndoClearShelf: @escaping () -> Bool = { false },
        onShowWelcome: @escaping () -> Void = {}
    ) {
        self.onShowPreferences = onShowPreferences
        self.onClearShelf = onClearShelf
        self.shelfCount = shelfCount
        self.onClearClipboard = onClearClipboard
        self.clipboardCount = clipboardCount
        self.onUndoClearShelf = onUndoClearShelf
        self.canUndoClearShelf = canUndoClearShelf
        self.onShowWelcome = onShowWelcome
    }

    public func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "rectangle.topthird.inset.filled",
            accessibilityDescription: "CreativeNotch"
        )

        let menu = NSMenu()
        menu.delegate = self

        // First, and reachable however the panel is configured. With every
        // tab-bearing module switched off the visible tab list is empty and
        // the panel has nowhere to open -- this is what makes that a legal
        // state rather than a trap.
        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(openPreferences),
            keyEquivalent: ","
        )
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        self.settingsItem = settings

        let clear = NSMenuItem(
            title: clearShelfTitle(),
            action: #selector(clearShelf),
            keyEquivalent: ""
        )
        clear.target = self
        clear.isEnabled = canClearShelf
        menu.addItem(clear)
        self.clearShelfItem = clear

        // Hidden rather than disabled: it exists for a few seconds after a
        // clear, and a greyed-out "Undo" the rest of the time is noise.
        let undoClear = NSMenuItem(
            title: "Undo Clear Shelf",
            action: #selector(undoClearShelf),
            keyEquivalent: ""
        )
        undoClear.target = self
        undoClear.isHidden = !showsUndoClearShelf
        menu.addItem(undoClear)
        self.undoClearShelfItem = undoClear

        let clearClipboard = NSMenuItem(
            title: clearClipboardTitle(),
            action: #selector(clearClipboard),
            keyEquivalent: ""
        )
        clearClipboard.target = self
        clearClipboard.isEnabled = clipboardCount() > 0
        menu.addItem(clearClipboard)
        self.clearClipboardItem = clearClipboard

        menu.addItem(.separator())

        // The way back to the first-run card (2026-10-24), for someone who
        // dismissed it too quickly. Here rather than in Settings because it
        // is about the panel: it opens the panel on the card, and the panel
        // opening under an activating Settings window would be hidden by it.
        let welcome = NSMenuItem(
            title: "Show Welcome Again",
            action: #selector(showWelcome),
            keyEquivalent: ""
        )
        welcome.target = self
        menu.addItem(welcome)
        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit CreativeNotch",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quit)

        item.menu = menu
        self.item = item
    }

    /// Read when the menu opens, never polled.
    func clearShelfTitle() -> String {
        let count = shelfCount()
        return count == 0 ? "Shelf is empty" : "Clear Shelf (\(count))"
    }

    @objc func clearShelf() {
        onClearShelf()
    }

    /// Read when the menu opens, never polled -- so an offer that lapses
    /// while the menu is open stays visible until it closes, and choosing
    /// it then does nothing.
    var showsUndoClearShelf: Bool { canUndoClearShelf() }

    /// Clear Shelf is offered only while there is something it would clear.
    var canClearShelf: Bool { shelfCount() > 0 }

    @objc func undoClearShelf() {
        onUndoClearShelf()
    }

    /// Read when the menu opens, never polled.
    func clearClipboardTitle() -> String {
        let count = clipboardCount()
        return count == 0 ? "Clipboard is empty" : "Clear Clipboard (\(count))"
    }

    @objc func clearClipboard() {
        onClearClipboard()
    }

    @objc func showWelcome() {
        onShowWelcome()
    }

    @objc private func openPreferences() {
        onShowPreferences()
    }
}

extension MenuBarController: NSMenuDelegate {
    /// Refreshes the dynamic titles each time the menu opens, so counts are
    /// current without anything polling on a timer.
    public func menuWillOpen(_ menu: NSMenu) {
        clearShelfItem?.title = clearShelfTitle()
        clearShelfItem?.isEnabled = canClearShelf
        undoClearShelfItem?.isHidden = !showsUndoClearShelf
        clearClipboardItem?.title = clearClipboardTitle()
        clearClipboardItem?.isEnabled = clipboardCount() > 0
    }
}
