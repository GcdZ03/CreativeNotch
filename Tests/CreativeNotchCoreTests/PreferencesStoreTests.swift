import Foundation
import Testing
@testable import CreativeNotchCore

struct PreferencesStoreTests {

    /// A fresh, isolated suite per test, cleared before use, so runs never see
    /// each other's state and never touch the real `com.gcdz.creativenotch`
    /// domain, never the developer's real one.
    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "com.gcdz.creativenotch.preferences-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    /// Drives the real read path against a genuinely empty domain rather than
    /// re-asserting the resolution function against itself. `dev.sh --fresh`
    /// produces exactly this state, so it is the one a developer hits daily.
    @Test func anEmptyDomainResolvesEveryModuleToItsShippedDefault() {
        let store = PreferencesStore(defaults: makeIsolatedDefaults())
        let loaded = store.load()
        for module in ModuleID.allCases {
            #expect(loaded[module] == module.shippedDefault, "\(module) came up wrong on a fresh domain")
        }
        #expect(loaded == Preferences.shipped)
        // The modules that ship off, read through the real path.
        #expect(loaded.calendar == false)
        #expect(loaded.bluetooth == false)
        #expect(loaded.downloads == false, "downloads came up on, and would prompt at launch")
    }

    /// Switched on once, the calendar stays on: an off-by-default module
    /// must persist `true`, not merely read as absent.
    @Test func theCalendarSwitchedOnSurvivesAReload() {
        let defaults = makeIsolatedDefaults()
        PreferencesStore(defaults: defaults).setEnabled(true, for: .calendar)
        #expect(PreferencesStore(defaults: defaults).load().calendar == true)
    }

    /// Off by default is not off for good: switched on, it stays on.
    @Test func downloadsSwitchedOnSurviveAReload() {
        let defaults = makeIsolatedDefaults()
        PreferencesStore(defaults: defaults).setEnabled(true, for: .downloads)
        #expect(PreferencesStore(defaults: defaults).load().downloads == true)
    }

    @Test func aDisabledModuleSurvivesAReload() {
        let defaults = makeIsolatedDefaults()
        let store = PreferencesStore(defaults: defaults)
        store.setEnabled(false, for: .clipboard)

        // A second store over the same suite: the value is in the domain, not
        // in the object that wrote it.
        let reloaded = PreferencesStore(defaults: defaults).load()
        #expect(reloaded.clipboard == false)
        for module in ModuleID.allCases where module != .clipboard {
            #expect(reloaded[module] == module.shippedDefault, "\(module) was disturbed by disabling clipboard")
        }
    }

    @Test func everyModuleCanBeSwitchedOffIndependently() {
        for module in ModuleID.allCases {
            let defaults = makeIsolatedDefaults()
            let store = PreferencesStore(defaults: defaults)
            store.setEnabled(false, for: module)

            let loaded = store.load()
            #expect(loaded[module] == false, "\(module) did not persist as off")
            for other in ModuleID.allCases where other != module {
                #expect(loaded[other] == other.shippedDefault, "disabling \(module) also changed \(other)")
            }
        }
    }

    @Test func switchingBackOnIsPersistedRatherThanJustClearingTheKey() {
        let defaults = makeIsolatedDefaults()
        let store = PreferencesStore(defaults: defaults)
        store.setEnabled(false, for: .clipboard)
        #expect(store.load().clipboard == false)

        store.setEnabled(true, for: .clipboard)
        #expect(store.load().clipboard == true)
        // An explicit `true` is written, not merely absent-and-defaulting.
        #expect(defaults.object(forKey: PreferenceKeys.enabled(.clipboard)) != nil)
    }

    /// The store writes under the documented key and nowhere else, so a person
    /// reading `defaults read com.gcdz.creativenotch` sees what the window did.
    @Test func theStoreWritesUnderTheDocumentedKey() {
        let defaults = makeIsolatedDefaults()
        PreferencesStore(defaults: defaults).setEnabled(false, for: .mediaMetadata)
        #expect(defaults.object(forKey: "module.media-metadata.enabled") as? NSNumber == NSNumber(value: false))
    }

    /// A value someone typed by hand in the wrong type does not brick the
    /// module -- it reads as the shipped default, and is left in place.
    @Test func aHandWrittenStringDoesNotDisableTheModule() {
        let defaults = makeIsolatedDefaults()
        defaults.set("yes", forKey: PreferenceKeys.enabled(.timer))

        #expect(PreferencesStore(defaults: defaults).load().timer == true)
        #expect(defaults.object(forKey: PreferenceKeys.enabled(.timer)) as? String == "yes")
    }

    /// The off-by-default module is read through the same resolver with its
    /// own shipped default: absent or mistyped stays off, a stored `true`
    /// turns it on. Load it with the generic `true` default and this fails.
    @Test func bluetoothStaysOffUntilSwitchedOn() {
        let defaults = makeIsolatedDefaults()
        let store = PreferencesStore(defaults: defaults)
        #expect(store.load().bluetooth == false)

        defaults.set("yes", forKey: PreferenceKeys.enabled(.bluetooth))
        #expect(store.load().bluetooth == false)

        store.setEnabled(true, for: .bluetooth)
        #expect(store.load().bluetooth == true)
    }

    // MARK: - Keep clear of app menus (2026-10-26)

    /// Off until switched on: switching it on is what asks for Accessibility
    /// access, and nobody should meet that prompt without asking for it.
    @Test func keepingClearOfMenusIsOffInAnEmptyDomain() {
        #expect(PreferencesStore(defaults: makeIsolatedDefaults()).pillClearsMenus == false)
    }

    @Test func keepingClearOfMenusSwitchedOnSurvivesAReloadUnderTheDocumentedKey() {
        let defaults = makeIsolatedDefaults()
        PreferencesStore(defaults: defaults).setPillClearsMenus(true)
        #expect(PreferencesStore(defaults: defaults).pillClearsMenus)
        #expect(defaults.object(forKey: "display.pillClearsMenus") as? Bool == true)
    }

    // MARK: - Timer notice and clipboard exclusions (2026-10-24)

    /// Absent means on: the notification is the only thing a full-screen
    /// user would see, and the setting is there to turn it off, not on.
    @Test func timerNoticesAreOnInAnEmptyDomain() {
        #expect(PreferencesStore(defaults: makeIsolatedDefaults()).timerNotifyWhenHidden)
    }

    @Test func timerNoticesSwitchedOffSurviveAReload() {
        let defaults = makeIsolatedDefaults()
        PreferencesStore(defaults: defaults).setTimerNotifyWhenHidden(false)
        #expect(defaults.object(forKey: "timer.notifyWhenHidden") as? Bool == false)
        #expect(PreferencesStore(defaults: defaults).timerNotifyWhenHidden == false)
    }

    @Test func clipboardExclusionsAreEmptyInAnEmptyDomain() {
        #expect(PreferencesStore(defaults: makeIsolatedDefaults()).clipboardExcludedApps == [])
    }

    @Test func clipboardExclusionsSurviveAReloadUnderTheDocumentedKey() {
        let defaults = makeIsolatedDefaults()
        PreferencesStore(defaults: defaults).setClipboardExcludedApps(["com.apple.Terminal", "com.b"])
        #expect(defaults.stringArray(forKey: "clipboard.excludedApps") == ["com.apple.Terminal", "com.b"])
        #expect(PreferencesStore(defaults: defaults).clipboardExcludedApps == ["com.apple.Terminal", "com.b"])
    }
}
