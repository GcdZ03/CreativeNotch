import Foundation
import Testing
@testable import CreativeNotchCore

// MARK: - SampledColor: what a pick is reduced to

/// Components arrive from the sampler as fractions and are kept as the 8-bit
/// sRGB channels every format prints, so two picks of the same pixel are
/// equal and the history can tell a repeat from a new colour.
@Test func aSampledColourRoundsItsComponentsToEightBits() {
    let color = SampledColor(red: 58.0 / 255, green: 123.4 / 255, blue: 212.6 / 255)
    #expect(color == SampledColor(red8: 58, green8: 123, blue8: 213))
}

/// A wide-gamut colour converted to sRGB can land just outside 0...1. Out of
/// range clamps rather than trapping on the `UInt8` conversion.
@Test func outOfRangeComponentsClampInsteadOfTrapping() {
    let color = SampledColor(red: -0.2, green: 1.4, blue: .nan)
    #expect(color == SampledColor(red8: 0, green8: 255, blue8: 0))
}

// MARK: - ColorFormat: the four ways a pick is copied

@Test func hexIsUppercaseWithAHash() {
    #expect(ColorFormat.hex.string(for: SampledColor(red8: 58, green8: 123, blue8: 213)) == "#3A7BD5")
    #expect(ColorFormat.hex.string(for: SampledColor(red8: 0, green8: 0, blue8: 0)) == "#000000")
    #expect(ColorFormat.hex.string(for: SampledColor(red8: 255, green8: 255, blue8: 255)) == "#FFFFFF")
}

@Test func rgbIsCSSFunctionalNotation() {
    #expect(ColorFormat.rgb.string(for: SampledColor(red8: 58, green8: 123, blue8: 213)) == "rgb(58, 123, 213)")
}

/// Reference values worked by hand from the CSS Color 4 algorithm, not read
/// back from the implementation.
@Test func hslMatchesTheCSSConversion() {
    #expect(ColorFormat.hsl.string(for: SampledColor(red8: 255, green8: 0, blue8: 0)) == "hsl(0, 100%, 50%)")
    #expect(ColorFormat.hsl.string(for: SampledColor(red8: 0, green8: 255, blue8: 0)) == "hsl(120, 100%, 50%)")
    #expect(ColorFormat.hsl.string(for: SampledColor(red8: 0, green8: 0, blue8: 255)) == "hsl(240, 100%, 50%)")
    #expect(ColorFormat.hsl.string(for: SampledColor(red8: 255, green8: 255, blue8: 255)) == "hsl(0, 0%, 100%)")
    #expect(ColorFormat.hsl.string(for: SampledColor(red8: 128, green8: 128, blue8: 128)) == "hsl(0, 0%, 50%)")
    #expect(ColorFormat.hsl.string(for: SampledColor(red8: 58, green8: 123, blue8: 213)) == "hsl(215, 65%, 53%)")
    // A magenta-side red, whose hue wraps below zero before it is normalised.
    #expect(ColorFormat.hsl.string(for: SampledColor(red8: 255, green8: 0, blue8: 128)) == "hsl(330, 100%, 50%)")
}

/// Pasteable as-is into Swift: three decimals is finer than one 8-bit step
/// (1/255 is about 0.0039), so the value round-trips to the same pixel.
@Test func swiftUIIsAPasteableInitialiser() {
    #expect(ColorFormat.swiftUI.string(for: SampledColor(red8: 58, green8: 123, blue8: 213))
            == "Color(red: 0.227, green: 0.482, blue: 0.835)")
    #expect(ColorFormat.swiftUI.string(for: SampledColor(red8: 255, green8: 0, blue8: 0))
            == "Color(red: 1.000, green: 0.000, blue: 0.000)")
}

/// The raw values are the stored preference, so they are a compatibility
/// surface in the same sense `ModuleID`'s are.
@Test func theFormatRawValuesAreUnchanged() {
    #expect(ColorFormat.hex.rawValue == "hex")
    #expect(ColorFormat.rgb.rawValue == "rgb")
    #expect(ColorFormat.hsl.rawValue == "hsl")
    #expect(ColorFormat.swiftUI.rawValue == "swiftui")
    #expect(ColorFormat.allCases == [.hex, .rgb, .hsl, .swiftUI])
    #expect(ColorFormat.default == .hex)
}

@Test func aStoredFormatResolvesByThePreferencesPolicy() {
    #expect(PreferenceKeys.resolveColorFormat(nil) == .hex)
    #expect(PreferenceKeys.resolveColorFormat("hsl") == .hsl)
    #expect(PreferenceKeys.resolveColorFormat("HSL") == .hex)
    #expect(PreferenceKeys.resolveColorFormat(3) == .hex)
}

// MARK: - ColorHistory: the last few picks, newest first

@Test func theHistoryKeepsTheNewestFirst() {
    var history = ColorHistory()
    let a = SampledColor(red8: 1, green8: 0, blue8: 0)
    let b = SampledColor(red8: 2, green8: 0, blue8: 0)
    history.record(a)
    history.record(b)
    #expect(history.colors == [b, a])
}

/// Picking a colour already in the history moves it to the front rather
/// than showing two swatches of one colour.
@Test func aRepeatMovesToTheFrontInsteadOfDuplicating() {
    var history = ColorHistory()
    let a = SampledColor(red8: 1, green8: 0, blue8: 0)
    let b = SampledColor(red8: 2, green8: 0, blue8: 0)
    history.record(a)
    history.record(b)
    history.record(a)
    #expect(history.colors == [a, b])
}

@Test func theHistoryDropsTheOldestPastItsCapacity() {
    var history = ColorHistory()
    #expect(ColorHistory.capacity == 5)
    for value in 0..<7 { history.record(SampledColor(red8: UInt8(value), green8: 0, blue8: 0)) }
    #expect(history.colors.count == 5)
    #expect(history.colors.first == SampledColor(red8: 6, green8: 0, blue8: 0))
    #expect(history.colors.last == SampledColor(red8: 2, green8: 0, blue8: 0))
}

@Test func clearingTheHistoryForgetsEverything() {
    var history = ColorHistory()
    history.record(SampledColor(red8: 1, green8: 2, blue8: 3))
    history.clear()
    #expect(history.colors.isEmpty)
}

// MARK: - ColorName: what VoiceOver says before the value

/// A hex value alone tells someone who cannot see the swatch nothing about
/// the colour, so the spoken label leads with a plain name.
@Test func theSpokenNameDescribesTheHue() {
    #expect(ColorName.name(for: SampledColor(red8: 255, green8: 0, blue8: 0)) == "red")
    #expect(ColorName.name(for: SampledColor(red8: 255, green8: 140, blue8: 0)) == "orange")
    #expect(ColorName.name(for: SampledColor(red8: 255, green8: 230, blue8: 0)) == "yellow")
    #expect(ColorName.name(for: SampledColor(red8: 0, green8: 200, blue8: 0)) == "green")
    #expect(ColorName.name(for: SampledColor(red8: 0, green8: 220, blue8: 220)) == "cyan")
    #expect(ColorName.name(for: SampledColor(red8: 58, green8: 123, blue8: 213)) == "blue")
    #expect(ColorName.name(for: SampledColor(red8: 140, green8: 40, blue8: 220)) == "purple")
    #expect(ColorName.name(for: SampledColor(red8: 255, green8: 80, blue8: 180)) == "pink")
}

@Test func greysAreNamedByLightnessNotHue() {
    #expect(ColorName.name(for: SampledColor(red8: 0, green8: 0, blue8: 0)) == "black")
    #expect(ColorName.name(for: SampledColor(red8: 255, green8: 255, blue8: 255)) == "white")
    #expect(ColorName.name(for: SampledColor(red8: 128, green8: 128, blue8: 130)) == "grey")
}

@Test func veryDarkOrLightHuesSayWhich() {
    #expect(ColorName.name(for: SampledColor(red8: 0, green8: 0, blue8: 90)) == "dark blue")
    #expect(ColorName.name(for: SampledColor(red8: 200, green8: 220, blue8: 255)) == "light blue")
}

@Test func theAccessibilityLabelPairsTheNameWithTheValue() {
    let color = SampledColor(red8: 58, green8: 123, blue8: 213)
    #expect(ColorName.spoken(color, as: .hex) == "blue, #3A7BD5")
}

// MARK: - The stored format

@Test func theFormatRoundTripsThroughTheStore() {
    let suite = "com.gcdz.creativenotch.color-tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = PreferencesStore(defaults: defaults)
    #expect(store.colorFormat == .hex)
    store.setColorFormat(.swiftUI)
    #expect(PreferencesStore(defaults: defaults).colorFormat == .swiftUI)
    #expect(defaults.string(forKey: PreferenceKeys.colorFormat) == "swiftui")
    #expect(PreferenceKeys.colorFormat == "color-picker.format")
}

/// A hand-typed value that names no format reads as hex and is left in
/// place, the policy every other stored setting follows.
@Test func aMangledStoredFormatReadsAsHexAndIsKept() {
    let suite = "com.gcdz.creativenotch.color-tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("cmyk", forKey: PreferenceKeys.colorFormat)
    #expect(PreferencesStore(defaults: defaults).colorFormat == .hex)
    #expect(defaults.string(forKey: PreferenceKeys.colorFormat) == "cmyk")
}
