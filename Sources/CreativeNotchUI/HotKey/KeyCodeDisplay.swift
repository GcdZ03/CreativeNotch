import AppKit
import Carbon.HIToolbox

/// Names a stored keycode on the keyboard layout in front of the user.
///
/// Resolution happens at **display** time, never at storage time. A keycode
/// identifies a physical key; which letter that key produces is a property of
/// the layout, and the layout changes.
public enum KeyCodeDisplay {

    /// The **ASCII-capable** input source, deliberately not the current one.
    ///
    /// `TISCopyCurrentKeyboardLayoutInputSource` is the obvious call and it is
    /// wrong here: with a Japanese or Pinyin IME selected it has no
    /// `kTISPropertyUnicodeKeyLayoutData` at all, `UCKeyTranslate` gets
    /// nothing, and the settings row renders blank for a key that works
    /// perfectly well.
    @MainActor
    public static func character(for keyCode: UInt32) -> String? {
        if let named = Self.namedKeys[keyCode] { return named }

        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?
            .takeRetainedValue(),
            let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }

        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)

        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.baseAddress?
                .assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(
                layout,
                UInt16(keyCode),
                UInt16(kUCKeyActionDisplay),
                0,                      // no modifiers: we want the bare legend
                UInt32(LMGetKbdType()),
                UInt32(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                characters.count,
                &length,
                &characters
            )
        }

        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length).uppercased()
    }

    /// Keys `UCKeyTranslate` renders as control characters or nothing at all.
    /// Space is the sharp one: it translates to " ", which in a settings row
    /// is indistinguishable from a missing key.
    static let namedKeys: [UInt32: String] = [
        UInt32(kVK_Space): "Space",
        UInt32(kVK_Return): "\u{21A9}",
        UInt32(kVK_Tab): "\u{21E5}",
        UInt32(kVK_Escape): "\u{238B}",
        UInt32(kVK_Delete): "\u{232B}",
        UInt32(kVK_ForwardDelete): "\u{2326}",
        UInt32(kVK_LeftArrow): "\u{2190}",
        UInt32(kVK_RightArrow): "\u{2192}",
        UInt32(kVK_UpArrow): "\u{2191}",
        UInt32(kVK_DownArrow): "\u{2193}",
        UInt32(kVK_Home): "\u{2196}",
        UInt32(kVK_End): "\u{2198}",
        UInt32(kVK_PageUp): "\u{21DE}",
        UInt32(kVK_PageDown): "\u{21DF}",
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3",
        UInt32(kVK_F4): "F4", UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6",
        UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8", UInt32(kVK_F9): "F9",
        UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
        UInt32(kVK_F13): "F13", UInt32(kVK_F14): "F14", UInt32(kVK_F15): "F15",
    ]
}
