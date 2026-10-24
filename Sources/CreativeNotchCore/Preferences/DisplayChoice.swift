import CoreGraphics

/// Which display the notch lives on: "Show on" in Settings (2026-10-24).
///
/// **Following focus is the default** because it is what the app did before
/// the setting existed: the panel follows `NSScreen.main`, the screen with the
/// key window, and is placed again on every app activation. On one display
/// that is invisible; on several it makes the pill hop to whichever display
/// was clicked last, which is what `builtIn` is for.
///
/// A specific external display, remembered by its UUID, was considered and
/// left out: it needs a picker whose options come and go with the cables and
/// a story for a remembered display that is not plugged in, while the case
/// people actually ask for -- "stay on the laptop" -- is this one.
public enum DisplayChoice: String, CaseIterable, Sendable {
    case focusedWindow = "focused-window"
    case builtIn = "built-in"

    public static let `default`: DisplayChoice = .focusedWindow

    /// The id of the screen the notch belongs on, or `nil` with no screens.
    ///
    /// A missing built-in display -- clamshell, a Mac mini, or the lid just
    /// closed -- falls back to following focus rather than leaving the notch
    /// nowhere, and no main screen (an accessory app may have no key window)
    /// falls back to the first, which is the one with the menu bar. A
    /// disconnected display is simply absent from `screens`, so the next
    /// call answers from what is left.
    public func screen(in screens: [ScreenDescriptor]) -> CGDirectDisplayID? {
        let focused = (screens.first(where: \.isMain) ?? screens.first)?.id
        switch self {
        case .focusedWindow:
            return focused
        case .builtIn:
            return screens.first(where: \.isBuiltIn)?.id ?? focused
        }
    }

    /// Whether another app coming forward is a reason to place the panel
    /// again. Pinned, it is not: the built-in display is the same display
    /// whichever app is frontmost, and asking on every Cmd-Tab is work the
    /// rule says not to do.
    public var followsActivation: Bool { self == .focusedWindow }

    /// The screen an app activation moves the notch to, or `nil` to leave it
    /// where it is.
    ///
    /// Stricter than `screen(in:)`: with no main screen (an accessory app
    /// with no key window came forward) the activation says nothing about
    /// where focus is, so it does not fall back to the first screen. That is
    /// what the app did before the setting -- it repositioned on activation
    /// only when `NSScreen.main` existed -- while the launch and a screen
    /// change, which must put the panel somewhere, keep the fallback.
    public func screenOnActivation(in screens: [ScreenDescriptor]) -> CGDirectDisplayID? {
        guard followsActivation, let main = screens.first(where: \.isMain) else { return nil }
        return main.id
    }
}

/// What the screen rule needs to know about one display, and nothing else.
///
/// Built from `NSScreen` and `CGDisplayIsBuiltin` in the UI target, kept
/// AppKit-free here for the reason `ScreenMetrics` is.
public struct ScreenDescriptor: Equatable, Sendable {
    public var id: CGDirectDisplayID
    public var isBuiltIn: Bool
    /// Holds the key window -- `NSScreen.main`.
    public var isMain: Bool

    public init(id: CGDirectDisplayID, isBuiltIn: Bool, isMain: Bool) {
        self.id = id
        self.isBuiltIn = isBuiltIn
        self.isMain = isMain
    }
}
