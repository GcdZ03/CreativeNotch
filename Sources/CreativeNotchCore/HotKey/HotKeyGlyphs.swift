import Foundation

/// Renders a combination the way macOS writes one.
///
/// **The order is fixed and is not the order the bits are defined in.** macOS
/// writes modifiers ⌃⌥⇧⌘ regardless of which the user pressed first, and a
/// pane that wrote ⌘⌥ where every menu in the system writes ⌥⌘ would look
/// wrong without anybody being able to say why.
public enum HotKeyGlyphs {

    public static let control = "\u{2303}"  // ⌃
    public static let option = "\u{2325}"   // ⌥
    public static let shift = "\u{21E7}"    // ⇧
    public static let command = "\u{2318}"  // ⌘

    /// The modifier glyphs alone, in macOS order.
    public static func modifiers(_ carbonModifiers: UInt32) -> String {
        var out = ""
        if carbonModifiers & HotKeyModifier.control != 0 { out += control }
        if carbonModifiers & HotKeyModifier.option != 0 { out += option }
        if carbonModifiers & HotKeyModifier.shift != 0 { out += shift }
        if carbonModifiers & HotKeyModifier.command != 0 { out += command }
        return out
    }

    /// The full label.
    ///
    /// `key` is resolved by the caller against the current keyboard layout,
    /// because that resolution needs `UCKeyTranslate` and belongs in UI. `nil`
    /// means the layout could not name the key -- which happens for real, with
    /// some IMEs -- and the keycode is shown instead, so the row degrades to
    /// something honest rather than to an empty string.
    public static func label(_ combo: HotKeyCombo, key: String?) -> String {
        modifiers(combo.carbonModifiers) + (key ?? "#\(combo.keyCode)")
    }
}
