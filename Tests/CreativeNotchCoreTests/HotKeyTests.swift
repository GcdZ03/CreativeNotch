import Foundation
import Testing
@testable import CreativeNotchCore

// MARK: - The stored value

/// Carbon's modifier bits are a persisted format, so a wrong value is a
/// preference that silently stops matching. Pinned by literal, the way
/// `ModuleID`'s raw values are.
@Test func theCarbonModifierBitsAreUnchanged() {
    #expect(HotKeyModifier.command == 0x0100)
    #expect(HotKeyModifier.shift == 0x0200)
    #expect(HotKeyModifier.option == 0x0800)
    #expect(HotKeyModifier.control == 0x1000)
    #expect(HotKeyModifier.all == 0x1B00)
}

/// The combination round-trips through the encoding that goes in the defaults
/// domain. A shape change here abandons the user's hotkey silently, because an
/// undecodable value reads as unset.
@Test func aComboSurvivesEncodingAndDecoding() throws {
    let combo = HotKeyCombo(keyCode: 45, carbonModifiers: HotKeyModifier.command | HotKeyModifier.option)
    let data = try JSONEncoder().encode(combo)
    let back = try JSONDecoder().decode(HotKeyCombo.self, from: data)
    #expect(back == combo)
}

// MARK: - AppKit to Carbon

/// A different bit layout, not a coincidence of naming. AppKit's command is
/// `1 << 20`; Carbon's is `0x0100`. One bit wrong here produces a recorder
/// that stores ⌥ when the user pressed ⌘ and then registers a combination
/// they never chose.
@Test func eachCocoaModifierMapsToItsCarbonCounterpart() {
    #expect(HotKeyModifier.carbon(fromCocoaRawValue: HotKeyModifier.Cocoa.command) == HotKeyModifier.command)
    #expect(HotKeyModifier.carbon(fromCocoaRawValue: HotKeyModifier.Cocoa.shift) == HotKeyModifier.shift)
    #expect(HotKeyModifier.carbon(fromCocoaRawValue: HotKeyModifier.Cocoa.option) == HotKeyModifier.option)
    #expect(HotKeyModifier.carbon(fromCocoaRawValue: HotKeyModifier.Cocoa.control) == HotKeyModifier.control)
}

@Test func modifiersCombineRatherThanReplacingEachOther() {
    let raw = HotKeyModifier.Cocoa.command | HotKeyModifier.Cocoa.option
    #expect(HotKeyModifier.carbon(fromCocoaRawValue: raw)
            == HotKeyModifier.command | HotKeyModifier.option)
}

/// Caps Lock, Fn and the numeric-pad bit that arrives with every arrow key are
/// not modifiers `RegisterEventHotKey` accepts. Passing them through would
/// refuse combinations that are perfectly valid.
@Test func modifiersMacOSAddsButCarbonDoesNotTakeAreDropped() {
    let capsLock: UInt = 1 << 16
    let numericPad: UInt = 1 << 21
    let function: UInt = 1 << 23

    #expect(HotKeyModifier.carbon(fromCocoaRawValue: capsLock) == 0)
    #expect(HotKeyModifier.carbon(fromCocoaRawValue: function) == 0)
    // An arrow key with Command carries the numeric-pad bit too.
    #expect(HotKeyModifier.carbon(fromCocoaRawValue: HotKeyModifier.Cocoa.command | numericPad)
            == HotKeyModifier.command)
}

@Test func noModifiersMapsToNoModifiers() {
    #expect(HotKeyModifier.carbon(fromCocoaRawValue: 0) == 0)
}

// MARK: - Validation

private let cmdOptN = HotKeyCombo(
    keyCode: 45,
    carbonModifiers: HotKeyModifier.command | HotKeyModifier.option
)

/// Registers cleanly -- all sixteen modifier subsets do, measured -- and would
/// then fire on every press of that key anywhere in the system, with no
/// warning from the API whatsoever.
@Test func aCombinationWithNoModifiersIsRefused() {
    let bare = HotKeyCombo(keyCode: 45, carbonModifiers: 0)
    #expect(HotKeyValidation.rejection(for: bare) == .noModifiers)
}

@Test func aBareShiftCombinationIsRefused() {
    let shifted = HotKeyCombo(keyCode: 45, carbonModifiers: HotKeyModifier.shift)
    #expect(HotKeyValidation.rejection(for: shifted) == .shiftOnly)
}

/// Shift with anything else is fine -- it is bare Shift that is one keypress
/// from ordinary typing.
@Test func shiftAlongsideAnotherModifierIsAccepted() {
    let combo = HotKeyCombo(
        keyCode: 45,
        carbonModifiers: HotKeyModifier.shift | HotKeyModifier.command
    )
    #expect(HotKeyValidation.rejection(for: combo) == nil)
}

/// The one conflict that IS detectable: same-process re-registration genuinely
/// returns -9878, so this is a claim the pane can honestly make.
@Test func aCombinationAlreadyUsedInThisAppIsRefused() {
    #expect(HotKeyValidation.rejection(for: cmdOptN, taken: [cmdOptN]) == .alreadyUsedInThisApp)
    #expect(HotKeyValidation.rejection(for: cmdOptN, taken: []) == nil)
}

/// macOS consumes its symbolic hotkeys before any application sees them, so
/// the registration would succeed and never deliver.
@Test func aCombinationMacOSOwnsIsRefused() {
    #expect(HotKeyValidation.rejection(for: cmdOptN, systemReserved: true) == .usedByMacOS)
}

/// Order matters, because the copy differs: an intra-app duplicate is the
/// user's own doing and is fixable by changing the other one, while a system
/// shortcut is not.
@Test func anIntraAppDuplicateOutranksASystemShortcut() {
    #expect(
        HotKeyValidation.rejection(for: cmdOptN, taken: [cmdOptN], systemReserved: true)
        == .alreadyUsedInThisApp
    )
}

/// Bits outside the four this project recognises are ignored rather than
/// treated as modifiers -- a value we did not write must not accidentally
/// satisfy the "has a modifier" rule.
@Test func unrecognisedModifierBitsDoNotCountAsModifiers() {
    let junk = HotKeyCombo(keyCode: 45, carbonModifiers: 0x0040)
    #expect(HotKeyValidation.rejection(for: junk) == .noModifiers)
}

// MARK: - Glyphs

/// macOS writes modifiers in a fixed order regardless of which the user
/// pressed first. A pane writing ⌘⌥ where every menu writes ⌥⌘ looks wrong
/// without anybody being able to say why.
@Test func modifiersAreRenderedInMacOSOrderNotBitOrder() {
    let all = HotKeyModifier.command | HotKeyModifier.shift
        | HotKeyModifier.option | HotKeyModifier.control
    #expect(HotKeyGlyphs.modifiers(all) == "\u{2303}\u{2325}\u{21E7}\u{2318}")

    // Pressed command-first, rendered option-first.
    #expect(HotKeyGlyphs.modifiers(HotKeyModifier.command | HotKeyModifier.option)
            == "\u{2325}\u{2318}")
}

@Test func aLabelPutsTheKeyAfterItsModifiers() {
    #expect(HotKeyGlyphs.label(cmdOptN, key: "N") == "\u{2325}\u{2318}N")
}

/// A layout that cannot name the key happens for real -- some IMEs have no
/// Unicode layout data at all -- and the row must degrade to something honest
/// rather than to an empty string.
@Test func aKeyTheLayoutCannotNameFallsBackToItsKeycode() {
    #expect(HotKeyGlyphs.label(cmdOptN, key: nil) == "\u{2325}\u{2318}#45")
}

// MARK: - Storage

private func isolatedDefaults() -> UserDefaults {
    let suiteName = "com.gcdz.creativenotch.hotkey-tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}

/// **Absent means genuinely absent**, unlike the module toggles whose absent
/// key resolves to ON. There is no default hotkey, and `nil` is a shipped
/// state rather than an error.
@Test func anEmptyDomainMeansNoHotkey() {
    #expect(HotKeyStore(defaults: isolatedDefaults()).load() == nil)
}

@Test func aSavedComboSurvivesAReload() {
    let defaults = isolatedDefaults()
    HotKeyStore(defaults: defaults).save(cmdOptN)
    #expect(HotKeyStore(defaults: defaults).load() == cmdOptN)
}

@Test func savingNilClearsTheStoredCombo() {
    let defaults = isolatedDefaults()
    let store = HotKeyStore(defaults: defaults)
    store.save(cmdOptN)
    store.save(nil)
    #expect(store.load() == nil)
}

/// A value of the wrong shape reads as absent and is NOT rewritten -- the same
/// policy the module toggles use, so the user keeps the evidence of whatever
/// they wrote.
@Test func aCorruptStoredValueReadsAsNoHotkey() {
    let defaults = isolatedDefaults()
    defaults.set(Data("not a combo".utf8), forKey: HotKeyStore.Keys.combo)

    #expect(HotKeyStore(defaults: defaults).load() == nil)
    #expect(defaults.data(forKey: HotKeyStore.Keys.combo) != nil, "the bad value was rewritten")
}

// MARK: - Confirmation

@Test func aFreshStoreHasNoConfirmation() {
    #expect(HotKeyStore(defaults: isolatedDefaults()).isConfirmed == false)
}

@Test func confirmingIsRemembered() {
    let defaults = isolatedDefaults()
    let store = HotKeyStore(defaults: defaults)
    store.save(cmdOptN)
    store.markConfirmed()

    #expect(HotKeyStore(defaults: defaults).isConfirmed)
}

/// **The proof was about the old combination.** Carrying it over would show a
/// tick beside a key nobody has ever pressed, which is worse than no tick.
@Test func changingTheComboClearsTheConfirmation() {
    let defaults = isolatedDefaults()
    let store = HotKeyStore(defaults: defaults)
    store.save(cmdOptN)
    store.markConfirmed()
    #expect(store.isConfirmed)

    store.save(HotKeyCombo(keyCode: 11, carbonModifiers: HotKeyModifier.command))

    #expect(store.isConfirmed == false)
}

/// Including clearing it entirely: unsetting the hotkey cannot leave a
/// confirmation behind for the next one.
@Test func clearingTheComboClearsTheConfirmation() {
    let defaults = isolatedDefaults()
    let store = HotKeyStore(defaults: defaults)
    store.save(cmdOptN)
    store.markConfirmed()

    store.save(nil)

    #expect(store.isConfirmed == false)
}
