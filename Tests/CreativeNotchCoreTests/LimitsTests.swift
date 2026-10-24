import Foundation
import Testing
@testable import CreativeNotchCore

/// The adjustable limits (2026-10-24): shelf capacity and expiry, clipboard
/// history size, the timer's presets and its chime.
///
/// Every default is today's hard-coded number, so a domain with none of these
/// keys behaves exactly as the app did before they existed.
struct LimitsTests {

    private func defaults() -> UserDefaults {
        let name = "com.gcdz.creativenotch.limits-tests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    // MARK: - The shipped defaults

    @Test func theDefaultsAreTheNumbersThatUsedToBeHardCoded() {
        let limits = Limits()
        #expect(limits.shelfCapacity == 20)
        #expect(limits.shelfExpiry == .sevenDays)
        #expect(limits.shelfExpiry.maxAge == TimeInterval(7 * 24 * 3600))
        #expect(limits.clipboardCapacity == 50)
        #expect(limits.timerPresets == [5, 10, 25])
        #expect(limits.chime == .glass)
    }

    @Test func theChoicesAreTheOnesOffered() {
        #expect(Limits.shelfCapacityChoices == [10, 20, 50])
        #expect(Limits.clipboardCapacityChoices == [25, 50, 100])
        #expect(ShelfExpiry.allCases == [.oneDay, .sevenDays, .thirtyDays, .never])
    }

    /// The defaults are among the choices, or the picker would open on a
    /// blank row.
    @Test func everyDefaultIsOneOfItsChoices() {
        #expect(Limits.shelfCapacityChoices.contains(Limits.defaultShelfCapacity))
        #expect(Limits.clipboardCapacityChoices.contains(Limits.defaultClipboardCapacity))
    }

    // MARK: - Shelf expiry

    @Test func neverMeansNoMaximumAge() {
        #expect(ShelfExpiry.never.maxAge == nil)
        #expect(ShelfExpiry.oneDay.maxAge == TimeInterval(24 * 3600))
        #expect(ShelfExpiry.thirtyDays.maxAge == TimeInterval(30 * 24 * 3600))
    }

    @Test func expiryLabelsReadAsSentences() {
        #expect(ShelfExpiry.oneDay.label == "1 day")
        #expect(ShelfExpiry.sevenDays.label == "7 days")
        #expect(ShelfExpiry.thirtyDays.label == "30 days")
        #expect(ShelfExpiry.never.label == "Never")
    }

    // MARK: - Chime

    /// The built-in alerts in `/System/Library/Sounds`, plus a way to have
    /// none at all. Exactly these: a name `NSSound` cannot find plays
    /// nothing, silently, which would read as a broken setting.
    @Test func theChimesAreTheBuiltInSoundsAndNone() {
        #expect(ChimeSound.allCases.map(\.rawValue) == [
            "None", "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero",
            "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink",
        ])
        #expect(ChimeSound.none.soundName == nil)
        #expect(ChimeSound.glass.soundName == "Glass")
    }

    // MARK: - Normalising the value

    /// A capacity that is not one of the choices reads as the default rather
    /// than being snapped to a neighbour: the only way to get one is a hand
    /// edit, and guessing what it meant is worse than ignoring it.
    @Test func aCapacityOffTheMenuFallsBackToTheDefault() {
        #expect(Limits(shelfCapacity: 33).shelfCapacity == 20)
        #expect(Limits(clipboardCapacity: 0).clipboardCapacity == 50)
        var limits = Limits()
        limits.shelfCapacity = -1
        limits.clipboardCapacity = 7
        #expect(limits.shelfCapacity == 20)
        #expect(limits.clipboardCapacity == 50)
    }

    @Test func presetsAreClampedToWhatACountdownAccepts() {
        let limits = Limits(timerPresets: [0, 500, 30])
        #expect(limits.timerPresets == [TimerStepper.minimum, TimerStepper.maximum, 30])
    }

    @Test func thereAreAlwaysExactlyThreePresets() {
        #expect(Limits(timerPresets: [1, 2]).timerPresets == Limits.defaultTimerPresets)
        #expect(Limits(timerPresets: [1, 2, 3, 4]).timerPresets == Limits.defaultTimerPresets)
        var limits = Limits()
        limits.timerPresets = []
        #expect(limits.timerPresets == Limits.defaultTimerPresets)
    }

    @Test func editingOnePresetClampsOnlyThatOne() {
        var limits = Limits()
        limits.timerPresets[1] = 1000
        #expect(limits.timerPresets == [5, TimerStepper.maximum, 25])
    }

    // MARK: - Resolving raw defaults values

    @Test func anEmptyDomainGivesTheShippedDefaults() {
        #expect(PreferencesStore(defaults: defaults()).loadLimits() == Limits())
    }

    @Test func whatIsSavedIsWhatLoads() {
        let d = defaults()
        let limits = Limits(
            shelfCapacity: 50, shelfExpiry: .never, clipboardCapacity: 100,
            timerPresets: [3, 45, 90], chime: .submarine
        )
        PreferencesStore(defaults: d).saveLimits(limits)
        // A second store over the same suite: the value lives in the domain.
        #expect(PreferencesStore(defaults: d).loadLimits() == limits)
    }

    /// Strings are not parsed, for the reason `resolveEnabled` gives:
    /// `defaults write` without `-int` writes one, and "20" working while
    /// "twenty" silently does not is a worse surprise than neither.
    @Test func wronglyTypedValuesReadAsTheDefaults() {
        let d = defaults()
        d.set("50", forKey: PreferenceKeys.shelfCapacity)
        d.set("never", forKey: PreferenceKeys.shelfExpiryDays)
        d.set("100", forKey: PreferenceKeys.clipboardCapacity)
        d.set(["5", "10", "25"], forKey: PreferenceKeys.timerPresets)
        d.set(7, forKey: PreferenceKeys.timerChime)
        #expect(PreferencesStore(defaults: d).loadLimits() == Limits())
    }

    /// And a wrong value is left in place, not corrected: the next `defaults
    /// read` should still show what was typed.
    @Test func aWronglyTypedValueIsNotRewritten() {
        let d = defaults()
        d.set("50", forKey: PreferenceKeys.shelfCapacity)
        _ = PreferencesStore(defaults: d).loadLimits()
        #expect(d.string(forKey: PreferenceKeys.shelfCapacity) == "50")
    }

    @Test func outOfRangeNumbersReadAsTheDefaults() {
        let d = defaults()
        d.set(33, forKey: PreferenceKeys.shelfCapacity)
        d.set(14, forKey: PreferenceKeys.shelfExpiryDays)
        d.set(1_000, forKey: PreferenceKeys.clipboardCapacity)
        d.set("Klaxon", forKey: PreferenceKeys.timerChime)
        #expect(PreferencesStore(defaults: d).loadLimits() == Limits())
    }

    /// A fractional number is not a capacity, even when it rounds to one.
    @Test func aFractionalCapacityReadsAsTheDefault() {
        #expect(Limits.resolveChoice(NSNumber(value: 20.5), among: [20], default: 10) == 10)
        #expect(Limits.resolveChoice(NSNumber(value: 20), among: [20], default: 10) == 20)
        #expect(Limits.resolveChoice(nil, among: [20], default: 10) == 10)
    }

    @Test func storedPresetsAreClampedNotDiscarded() {
        let d = defaults()
        d.set([0, 45, 900], forKey: PreferenceKeys.timerPresets)
        #expect(PreferencesStore(defaults: d).loadLimits().timerPresets
                == [TimerStepper.minimum, 45, TimerStepper.maximum])
    }

    @Test func aChimeIsMatchedExactly() {
        #expect(Limits.resolveChime("Ping") == .ping)
        #expect(Limits.resolveChime("None") == ChimeSound.none)
        #expect(Limits.resolveChime("ping") == .glass)
        #expect(Limits.resolveChime(nil) == .glass)
    }

    /// Nothing is cached: a value written behind the store's back is what
    /// the next load sees.
    @Test func itReadsTheDomainEveryTime() {
        let d = defaults()
        let store = PreferencesStore(defaults: d)
        _ = store.loadLimits()
        d.set(10, forKey: PreferenceKeys.shelfCapacity)
        #expect(store.loadLimits().shelfCapacity == 10)
    }

    /// The keys namespace like the module toggles do: by subsystem first.
    @Test func theKeysAreSpelledOnce() {
        #expect(PreferenceKeys.shelfCapacity == "shelf.capacity")
        #expect(PreferenceKeys.shelfExpiryDays == "shelf.expiryDays")
        #expect(PreferenceKeys.clipboardCapacity == "clipboard.capacity")
        #expect(PreferenceKeys.timerPresets == "timer.presets")
        #expect(PreferenceKeys.timerChime == "timer.chime")
    }
}
