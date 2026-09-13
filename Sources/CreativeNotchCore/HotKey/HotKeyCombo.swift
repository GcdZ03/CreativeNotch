import Foundation

/// A key combination, as the two integers the window server wants.
///
/// **A keycode, never a character.** `RegisterEventHotKey` takes a virtual
/// keycode identifying a *physical* key; the letter printed on that key is a
/// rendering concern that changes with the keyboard layout. Storing the
/// character would mean reverse-mapping it against whatever layout happened to
/// be current at load time, which is wrong the moment the user switches
/// layouts -- and silently wrong, because the reverse map usually succeeds.
///
/// The modifier mask is Carbon's, not AppKit's. They are different bit
/// layouts, and this is the one that goes to the API and into the defaults
/// domain, so it is the one stored.
public struct HotKeyCombo: Codable, Hashable, Sendable {

    /// A `kVK_*` virtual keycode. Numerically equal to `NSEvent.keyCode`.
    public var keyCode: UInt32

    /// `cmdKey | optionKey | shiftKey | controlKey`, Carbon's layout.
    public var carbonModifiers: UInt32

    public init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }
}

/// Carbon's modifier bits, named.
///
/// Duplicated from `Carbon.HIToolbox` rather than imported: Core stays free of
/// UI frameworks, and these four constants have been stable since the 1990s.
/// Pinned by literal in the tests for the same reason `ModuleID`'s raw values
/// are -- they are a persisted format, so a wrong value is a preference that
/// silently stops matching.
public enum HotKeyModifier {
    public static let command: UInt32 = 0x0100
    public static let shift: UInt32 = 0x0200
    public static let option: UInt32 = 0x0800
    public static let control: UInt32 = 0x1000

    /// Every bit this project recognises. Anything outside it in a stored
    /// value is a value we did not write.
    public static let all: UInt32 = command | shift | option | control

    /// AppKit's `NSEvent.ModifierFlags` bits, by raw value.
    ///
    /// Named here rather than imported so the conversion below stays in Core,
    /// where it is testable. These are a *different layout* from Carbon's --
    /// AppKit's command is `1 << 20`, Carbon's is `0x0100` -- which is exactly
    /// why the mapping is worth writing down and worth a test. Getting one bit
    /// wrong produces a recorder that stores ⌥ when the user pressed ⌘, and
    /// then registers a combination they never chose.
    public enum Cocoa {
        public static let shift: UInt = 1 << 17
        public static let control: UInt = 1 << 18
        public static let option: UInt = 1 << 19
        public static let command: UInt = 1 << 20
    }

    /// Converts AppKit's modifier flags to Carbon's.
    ///
    /// Takes the raw value rather than `NSEvent.ModifierFlags` so Core need
    /// not import AppKit. Everything outside the four recognised modifiers --
    /// Caps Lock, Fn, the numeric-pad bit that arrives with every arrow key --
    /// is dropped, because none of them is a modifier `RegisterEventHotKey`
    /// accepts and passing them through would refuse combinations that are
    /// perfectly valid.
    public static func carbon(fromCocoaRawValue raw: UInt) -> UInt32 {
        var out: UInt32 = 0
        if raw & Cocoa.command != 0 { out |= command }
        if raw & Cocoa.shift != 0 { out |= shift }
        if raw & Cocoa.option != 0 { out |= option }
        if raw & Cocoa.control != 0 { out |= control }
        return out
    }
}
