import Foundation

/// Whether a combination is one this app will accept, and why not.
///
/// **What this deliberately cannot answer: whether another application already
/// holds the combination.** Measured, and there is no API for it -- an
/// ordinary conflict returns `noErr` and both handlers fire. See
/// `docs/research/2026-09-13-hotkey-probe.md`. Anything here that claimed
/// otherwise would be a lie the system cannot back up.
public enum HotKeyValidation {

    public enum Rejection: Equatable, Sendable {
        /// No modifiers at all. Registers cleanly -- measured, all sixteen
        /// subsets do -- and would then fire on every press of that key
        /// anywhere in the system, with no warning from the API.
        case noModifiers

        /// A bare Shift combination. It registers on macOS 26, but it is one
        /// keypress away from ordinary typing.
        case shiftOnly

        /// Already bound to something else inside CreativeNotch. This is the
        /// one conflict that IS detectable: same-process re-registration
        /// genuinely returns -9878.
        case alreadyUsedInThisApp

        /// `CopySymbolicHotKeys` lists it as an enabled system shortcut. The
        /// system consumes those before any application sees them, so the
        /// registration would succeed and never deliver.
        case usedByMacOS
    }

    /// - Parameters:
    ///   - taken: combinations already bound inside this app.
    ///   - systemReserved: whether macOS lists this as a symbolic hotkey. The
    ///     caller reads that, because `CopySymbolicHotKeys` is a UI-layer call
    ///     and Apple's header warns against calling it unnecessarily -- so it
    ///     arrives here as a value, the same shape `PowerController` takes its
    ///     snapshots in.
    public static func rejection(
        for combo: HotKeyCombo,
        taken: [HotKeyCombo] = [],
        systemReserved: Bool = false
    ) -> Rejection? {
        let modifiers = combo.carbonModifiers & HotKeyModifier.all

        if modifiers == 0 { return .noModifiers }
        if modifiers == HotKeyModifier.shift { return .shiftOnly }
        if taken.contains(combo) { return .alreadyUsedInThisApp }
        if systemReserved { return .usedByMacOS }
        return nil
    }

    public static func isAcceptable(
        _ combo: HotKeyCombo,
        taken: [HotKeyCombo] = [],
        systemReserved: Bool = false
    ) -> Bool {
        rejection(for: combo, taken: taken, systemReserved: systemReserved) == nil
    }
}
