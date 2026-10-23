import AppKit
import Carbon.HIToolbox
import CreativeNotchCore

/// The conflict `RegisterEventHotKey` will not tell you about.
///
/// macOS consumes its own symbolic hotkeys before any application sees them,
/// so a combination like ⌘Space registers with `noErr` and then never
/// delivers. This is the only way to see that coming.
///
/// **It cannot name which feature owns a combination** -- there is no API for
/// that -- so the copy has to say "macOS already uses this" and stop there.
public enum SymbolicHotKeys {

    /// Called **once**, at the moment the user picks a combination. Apple's
    /// header warns this is O(number of hotkeys) and says not to call it
    /// unnecessarily, so it is never on a redraw path.
    @MainActor
    public static func isReserved(_ combo: HotKeyCombo) -> Bool {
        var out: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&out) == noErr,
              let entries = out?.takeRetainedValue() as? [[String: Any]]
        else { return false }
        return isReserved(combo, in: entries)
    }

    /// The matching, separated from the read so it can be tested against
    /// entries a test supplies rather than whatever this machine holds.
    ///
    /// **Both sides are masked to the four recognised modifiers.** The system
    /// stores extra bits alongside them -- the function-key and numeric-pad
    /// flags that come with every arrow key, so Spaces' ⌃← is not stored as
    /// plain ⌃ -- while the recorder strips those bits. An exact comparison
    /// would never match such an entry and would call ⌃← free.
    static func isReserved(_ combo: HotKeyCombo, in entries: [[String: Any]]) -> Bool {
        let wanted = combo.carbonModifiers & HotKeyModifier.all
        for entry in entries {
            // Disabled symbolic hotkeys do not consume anything, so they are
            // not conflicts. A user who turned Spotlight's shortcut off has
            // freed that combination.
            guard (entry[kHISymbolicHotKeyEnabled as String] as? Bool) == true,
                  let code = entry[kHISymbolicHotKeyCode as String] as? UInt32,
                  let modifiers = entry[kHISymbolicHotKeyModifiers as String] as? UInt32
            else { continue }

            if code == combo.keyCode && modifiers & HotKeyModifier.all == wanted { return true }
        }
        return false
    }
}
