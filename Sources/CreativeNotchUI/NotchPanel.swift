import AppKit
import QuickLookUI
import CreativeNotchCore

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
    /// So this is `true` for three things only: the timer's custom-minutes
    /// field, the clipboard's search field, and keyboard
    /// control (Esc, ⌘1…⌘N) of a panel somebody opened on purpose.
    /// `AppDelegate` makes the panel key on the timer tab and on
    /// an explicit open — the notch tap, the shortcut — never on a hover-open
    /// or a peek, and hands focus straight back on close. See
    /// `syncKeyWindow` and `PanelFocus`.
    ///
    /// `canBecomeMain` stays `false`: main is for a document window that
    /// owns the app's menus, which this is not.
    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }

    // MARK: - Keys

    /// Where a decoded key goes; returns whether it was used. Set by
    /// `AppDelegate.install`, which routes it through the state funnel —
    /// the panel decodes, it never decides (`PanelKeyboard`).
    ///
    /// Handled here, in the window, rather than with SwiftUI's
    /// `.onKeyPress`, because those need a focused view and the open panel
    /// mostly has none: the shelf is click-only, and the clipboard's search
    /// field is often not the one focused. Every
    /// key the panel receives passes through the window whatever has focus.
    /// And it costs nothing at idle — keys only arrive while the panel is
    /// key, so there is no monitor to install or remove.
    public var onPanelKey: ((PanelKey) -> Bool)?

    /// The number row's key codes for 1…9, in order.
    ///
    /// By key code, not by character, for the reason the global shortcut
    /// stores one: ⌘2 means the second key of the number row on every
    /// layout. On AZERTY the unshifted character there is "é".
    private static let digitKeyCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

    private static let escapeKeyCode: UInt16 = 53
    private static let spaceKeyCode: UInt16 = 49
    private static let leftArrowKeyCode: UInt16 = 123
    private static let rightArrowKeyCode: UInt16 = 124

    /// The key an event stands for, or `nil` when it is not one of ours.
    ///
    /// Digits count only with exactly ⌘ held: a plain digit is typing — the
    /// timer's minutes field — and ⌘⇧2 or ⌥⌘2 belong to somebody else.
    /// Only ⇧ ⌃ ⌥ ⌘ make a chord. Caps Lock, the numeric-pad and function
    /// flags are states of the keyboard rather than parts of one — the
    /// arrow keys always arrive with the last two set — and so is any bit
    /// AppKit has no name for: a synthesized key event (an automation tool,
    /// the live Quick Look suite) arrives carrying bit 29, which a mask
    /// that only *subtracted* the known states read as a modifier held,
    /// so Space and the arrows silently stopped being ours.
    ///
    /// Space and ← → count only bare: ⌘Space is Spotlight's and ⌥← a word
    /// jump. Whether they *do* anything is `PanelKeyboard`'s call — only on
    /// the shelf tab.
    public static func panelKey(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> PanelKey? {
        let chord = modifiers.intersection([.shift, .control, .option, .command])
        if chord.isEmpty {
            switch keyCode {
            case escapeKeyCode:     return .escape
            case spaceKeyCode:      return .space
            case leftArrowKeyCode:  return .arrowLeft
            case rightArrowKeyCode: return .arrowRight
            default:                break
            }
        }
        guard chord == .command, let index = digitKeyCodes.firstIndex(of: keyCode) else { return nil }
        return .commandDigit(index + 1)
    }

    private func handle(_ key: PanelKey?) -> Bool {
        guard let key, let onPanelKey else { return false }
        return onPanelKey(key)
    }

    /// ⌘1…⌘N. AppKit offers ⌘-chords to the key window as key equivalents
    /// before any view sees them, so a focused text field cannot eat one.
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let key = Self.panelKey(keyCode: event.keyCode, modifiers: event.modifierFlags)
        if case .commandDigit = key, handle(key) { return true }
        if firstResponder is NSText,
           let action = Self.editingAction(
               characters: event.charactersIgnoringModifiers, modifiers: event.modifierFlags),
           NSApp.sendAction(action, to: nil, from: self) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// ⌘X, ⌘C, ⌘V, ⌘A and ⌘Z for a field being edited in the panel — the
    /// clipboard search above all, where pasting a word is the obvious way
    /// to look for it.
    ///
    /// An `.accessory` app has no main menu, and those chords are menu key
    /// equivalents everywhere else: without this they reach the field
    /// editor as nothing at all. By character rather than key code, unlike
    /// ⌘1…⌘N, because that is how the system's own Edit menu matches them —
    /// ⌘V is the key labelled V on Dvorak as on QWERTY. Only while a field
    /// editor is first responder, so the chords mean nothing anywhere else
    /// in the panel.
    static func editingAction(characters: String?, modifiers: NSEvent.ModifierFlags) -> Selector? {
        // Only ⇧ ⌃ ⌥ ⌘ make a chord, as in `panelKey`: subtracting the known
        // keyboard states left bit 29 in, which a ⌘V sent by an automation
        // tool carries, and it stopped matching.
        let chord = modifiers.intersection([.shift, .control, .option, .command])
        guard chord == .command, let character = characters?.lowercased() else { return nil }
        switch character {
        case "x": return #selector(NSText.cut(_:))
        case "c": return #selector(NSText.copy(_:))
        case "v": return #selector(NSText.paste(_:))
        case "a": return #selector(NSText.selectAll(_:))
        case "z": return Selector(("undo:"))
        default:  return nil
        }
    }

    /// Esc, Space and the arrows with nothing focused: the key-down falls
    /// through the responder chain to the window. A focused text field —
    /// the timer's minutes — consumes Space and the arrows itself, so they
    /// never reach here while someone is typing.
    public override func keyDown(with event: NSEvent) {
        // ⌘N was offered as a key equivalent already; declined there, it is
        // declined here too.
        let key = Self.panelKey(keyCode: event.keyCode, modifiers: event.modifierFlags)
        switch key {
        case .escape?, .space?, .arrowLeft?, .arrowRight?:
            if handle(key) { return }
        case .commandDigit?, nil:
            break
        }
        super.keyDown(with: event)
    }

    /// Esc while a text field is editing: the field editor turns it into
    /// `cancelOperation(_:)` and sends it up the chain, so it arrives here
    /// rather than as a key-down. Both routes are one callback, and only one
    /// of them fires for a single press.
    public override func cancelOperation(_ sender: Any?) {
        if handle(.escape) { return }
        super.cancelOperation(sender)
    }

    // MARK: - Quick Look

    /// The shelf's Quick Look controller, set by `AppDelegate.install` when
    /// the real one is in use. Weak: the delegate owns it.
    weak var quickLook: ShelfQuickLook?

    /// `QLPreviewPanel` walks the key window's responder chain for a
    /// controller; the panel is where that walk starts while it is key, so
    /// this is where the shelf answers. See `ShelfQuickLook` for why the
    /// controller is also handed over directly.
    ///
    /// Quick Look calls these on the main thread; the informal protocol
    /// they come from predates the annotation that would say so.
    public override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated { quickLook?.request != nil }
    }

    public override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        guard let panel else { return }
        MainActor.assumeIsolated { quickLook?.attach(to: panel) }
    }

    public override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        guard let panel else { return }
        MainActor.assumeIsolated { quickLook?.detach(from: panel) }
    }

    public init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear

        // The panel draws itself black, always, on every system theme. Its
        // *appearance* has to say so, or AppKit resolves semantic colours
        // against the user's system setting instead.
        //
        // This is not cosmetic. Under Light appearance, `.bordered`
        // buttons resolve their label to `labelColor` — near-black — and
        // draw it on this panel's black background. The Pause and Cancel
        // buttons were invisible: rendered, hit-testable, and unreadable.
        //
        // Nothing caught it because every other view in the project styles
        // its own text explicitly (`.white.opacity(...)` with
        // `.buttonStyle(.plain)`) and so never asks the appearance
        // anything. The timer tab is the first to use stock controls. The
        // rendering tests could not have caught it either: `ImageRenderer`
        // has no window, so there is no appearance for a semantic colour to
        // resolve against.
        appearance = NSAppearance(named: .darkAqua)
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    }
}
