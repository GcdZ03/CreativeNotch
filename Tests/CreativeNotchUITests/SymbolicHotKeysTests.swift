import Carbon.HIToolbox
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// Matching a chosen combination against `CopySymbolicHotKeys`' entries.
///
/// The entries are handed in rather than read, so this asserts the matching
/// and not whatever this machine's System Settings happen to hold.
struct SymbolicHotKeysTests {

    private func entry(code: Int, modifiers: UInt32, enabled: Bool = true) -> [String: Any] {
        [
            kHISymbolicHotKeyCode as String: UInt32(code),
            kHISymbolicHotKeyModifiers as String: modifiers,
            kHISymbolicHotKeyEnabled as String: enabled,
        ]
    }

    @Test func anEnabledExactMatchIsReserved() {
        let combo = HotKeyCombo(keyCode: UInt32(kVK_Space), carbonModifiers: HotKeyModifier.command)
        let entries = [entry(code: kVK_Space, modifiers: HotKeyModifier.command)]
        #expect(SymbolicHotKeys.isReserved(combo, in: entries))
    }

    /// A user who switched Spotlight's shortcut off has freed it.
    @Test func aDisabledEntryIsNotReserved() {
        let combo = HotKeyCombo(keyCode: UInt32(kVK_Space), carbonModifiers: HotKeyModifier.command)
        let entries = [entry(code: kVK_Space, modifiers: HotKeyModifier.command, enabled: false)]
        #expect(SymbolicHotKeys.isReserved(combo, in: entries) == false)
    }

    /// **The system stores extra bits alongside the four modifiers** -- the
    /// function-key and numeric-pad flags that arrive with every arrow key.
    /// Spaces' ⌃← is stored with them, while the recorder strips them, so an
    /// exact comparison never matches and ⌃← sails through as free.
    @Test func extraSystemBitsDoNotHideAReservation() {
        let combo = HotKeyCombo(keyCode: UInt32(kVK_LeftArrow), carbonModifiers: HotKeyModifier.control)
        let fnAndKeypad: UInt32 = 0x80_0000 | 0x20_0000
        let entries = [entry(code: kVK_LeftArrow, modifiers: HotKeyModifier.control | fnAndKeypad)]
        #expect(SymbolicHotKeys.isReserved(combo, in: entries))
    }

    /// Masking must not loosen the match: a different modifier set is still
    /// a different combination.
    @Test func aDifferentModifierSetIsNotReserved() {
        let combo = HotKeyCombo(
            keyCode: UInt32(kVK_LeftArrow),
            carbonModifiers: HotKeyModifier.control | HotKeyModifier.option
        )
        let entries = [entry(code: kVK_LeftArrow, modifiers: HotKeyModifier.control | 0x80_0000)]
        #expect(SymbolicHotKeys.isReserved(combo, in: entries) == false)
    }
}
