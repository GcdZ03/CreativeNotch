import Foundation
import Testing
@testable import CreativeNotchCore

// MARK: - ModuleID raw values are a compatibility surface

/// Pinned by literal for the same reason `TimerTabTests` pins `Tab`'s: these
/// raw values are the middle segment of a shipped defaults key. Renaming one
/// does not migrate the preference behind it, it abandons it -- and because an
/// absent key resolves to *on*, the symptom is the module the user switched off
/// coming back, with nothing failing.
@Test func theModuleRawValuesAreUnchanged() {
    #expect(ModuleID.shelf.rawValue == "shelf")
    #expect(ModuleID.clipboard.rawValue == "clipboard")
    #expect(ModuleID.mediaMetadata.rawValue == "media-metadata")
    #expect(ModuleID.mediaControls.rawValue == "media-controls")
    #expect(ModuleID.power.rawValue == "power")
    #expect(ModuleID.timer.rawValue == "timer")
    #expect(ModuleID.hotkey.rawValue == "hotkey")
    #expect(ModuleID.camera.rawValue == "camera")
    #expect(ModuleID.captureIndicator.rawValue == "capture-indicator")
    #expect(ModuleID.bluetooth.rawValue == "bluetooth")
    #expect(ModuleID.calendar.rawValue == "calendar")
    #expect(ModuleID.colorPicker.rawValue == "color-picker")
}

@Test func everyModuleHasADistinctKey() {
    let keys = ModuleID.allCases.map(PreferenceKeys.enabled)
    #expect(keys.count == 12)
    #expect(Set(keys).count == keys.count)
    #expect(keys.allSatisfy { $0.hasPrefix("module.") && $0.hasSuffix(".enabled") })
}

@Test func theKeyIsTheRawValueWrappedInTheScheme() {
    #expect(PreferenceKeys.enabled(.mediaMetadata) == "module.media-metadata.enabled")
    #expect(PreferenceKeys.enabled(.clipboard) == "module.clipboard.enabled")
}

// MARK: - Resolution: the entire compatibility surface

/// The single most likely way to ship this module broken. `bool(forKey:)`
/// returns `false` for an absent key, which for a set of enable-flags means a
/// fresh install comes up with everything switched off.
@Test func anAbsentValueMeansTheModuleIsOn() {
    #expect(PreferenceKeys.resolveEnabled(nil) == true)
}

@Test func aStoredBooleanIsHonoured() {
    #expect(PreferenceKeys.resolveEnabled(NSNumber(value: false)) == false)
    #expect(PreferenceKeys.resolveEnabled(NSNumber(value: true)) == true)
}

/// `defaults write ... -string yes` is a thing people do. They get working
/// software, and their typo stays visible to them rather than being silently
/// overwritten.
@Test func aValueOfTheWrongTypeMeansTheShippedDefault() {
    #expect(PreferenceKeys.resolveEnabled("yes") == true)
    #expect(PreferenceKeys.resolveEnabled("false") == true)
    #expect(PreferenceKeys.resolveEnabled(Data()) == true)
    #expect(PreferenceKeys.resolveEnabled(["a"]) == true)
}

/// The shipped default is a parameter rather than a constant so the first
/// tunable to ship off-by-default cannot silently invert.
@Test func theShippedDefaultIsWhatAnAbsentOrMistypedValueFallsBackTo() {
    #expect(PreferenceKeys.resolveEnabled(nil, shippedDefault: false) == false)
    #expect(PreferenceKeys.resolveEnabled("yes", shippedDefault: false) == false)
    // A real stored value still wins over the shipped default.
    #expect(PreferenceKeys.resolveEnabled(NSNumber(value: true), shippedDefault: false) == true)
}

// MARK: - The value

@Test func preferencesShipWithEverythingOnButTheCalendar() {
    for module in ModuleID.allCases {
        #expect(Preferences.allEnabled[module] == true)
        #expect(Preferences.shipped[module] == (module != .calendar && module != .bluetooth), "\(module)")
        #expect(Preferences.shipped[module] == module.shippedDefault)
    }
}

/// Bluetooth alerts and the calendar are the modules that ship off: each
/// needs a permission, and a permission is asked for when someone switches
/// the feature on -- never at launch, and never for a feature nobody chose.
/// Everything else needs no grant and costs nothing at rest, so it stays on.
@Test func onlyThePermissionModulesShipOff() {
    for module in ModuleID.allCases {
        #expect(module.shippedDefault == (module != .bluetooth && module != .calendar), "\(module)")
        #expect(Preferences.shipped[module] == module.shippedDefault, "\(module)")
    }
}

@Test func theCalendarShipsOffBecauseItNeedsAPermission() {
    #expect(ModuleID.calendar.shippedDefault == false)
    #expect(Preferences().calendar == false)
    #expect(Preferences().bluetooth == false)
}

@Test func theSubscriptReachesEveryModuleIndependently() {
    for module in ModuleID.allCases {
        var preferences = Preferences.allEnabled
        preferences[module] = false
        #expect(preferences[module] == false)
        // Switching one module off leaves the other six alone.
        for other in ModuleID.allCases where other != module {
            #expect(preferences[other] == true, "\(module) leaked into \(other)")
        }
    }
}
