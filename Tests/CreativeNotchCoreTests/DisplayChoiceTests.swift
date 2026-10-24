import Foundation
import Testing
@testable import CreativeNotchCore

/// "Show on" (2026-10-24): which display the notch lives on.
///
/// Every branch of the rule is exercised against plain descriptors, because
/// the real inputs -- `NSScreen.screens`, `CGDisplayIsBuiltin` -- cannot be
/// rearranged from a test, and the cases that matter most (clamshell, a
/// display unplugged mid-session) are exactly the ones a developer's desk
/// never reproduces.
struct DisplayChoiceTests {

    private let builtIn = ScreenDescriptor(id: 1, isBuiltIn: true, isMain: false)
    private let external = ScreenDescriptor(id: 2, isBuiltIn: false, isMain: false)
    private let externalMain = ScreenDescriptor(id: 2, isBuiltIn: false, isMain: true)
    private let builtInMain = ScreenDescriptor(id: 1, isBuiltIn: true, isMain: true)
    private let secondExternal = ScreenDescriptor(id: 3, isBuiltIn: false, isMain: false)

    // MARK: - Following focus (the default, and the behaviour before the setting)

    @Test func theDefaultFollowsTheFocusedWindow() {
        #expect(DisplayChoice.default == .focusedWindow)
    }

    @Test func followingFocusPicksTheMainScreen() {
        #expect(DisplayChoice.focusedWindow.screen(in: [builtIn, externalMain]) == 2)
        #expect(DisplayChoice.focusedWindow.screen(in: [builtInMain, external]) == 1)
    }

    /// An accessory app may have no key window at all, so no main screen --
    /// any screen will do, the first being the one with the menu bar.
    @Test func followingFocusWithNoMainScreenTakesTheFirst() {
        #expect(DisplayChoice.focusedWindow.screen(in: [external, builtIn]) == 2)
    }

    // MARK: - Pinned to the built-in display

    @Test func builtInIgnoresWhereFocusIs() {
        #expect(DisplayChoice.builtIn.screen(in: [externalMain, builtIn]) == 1)
        #expect(DisplayChoice.builtIn.screen(in: [builtInMain, external]) == 1)
    }

    /// Clamshell, or a desktop Mac: there is no built-in display, so it
    /// behaves as following focus rather than leaving the notch nowhere.
    @Test func builtInWithNoBuiltInFallsBackToTheMainScreen() {
        #expect(DisplayChoice.builtIn.screen(in: [external, ScreenDescriptor(id: 3, isBuiltIn: false, isMain: true)]) == 3)
    }

    @Test func builtInWithNoBuiltInAndNoMainTakesTheFirst() {
        #expect(DisplayChoice.builtIn.screen(in: [secondExternal, external]) == 3)
    }

    /// The lid closed, or the built-in otherwise gone, is simply a list
    /// without it: the next answer comes from what is left.
    @Test func builtInDisconnectedMovesToWhatRemains() {
        #expect(DisplayChoice.builtIn.screen(in: [builtIn, externalMain]) == 1)
        #expect(DisplayChoice.builtIn.screen(in: [externalMain]) == 2)
    }

    @Test func noScreensChoosesNothing() {
        for choice in DisplayChoice.allCases {
            #expect(choice.screen(in: []) == nil)
        }
    }

    // MARK: - Activation

    /// Only following focus has any reason to look again when an app comes
    /// forward; pinned, an app switch must not move the notch.
    @Test func onlyFollowingFocusRepositionsOnActivation() {
        #expect(DisplayChoice.focusedWindow.followsActivation)
        #expect(!DisplayChoice.builtIn.followsActivation)
    }

    /// An activation names a screen only when there is a main one: with no
    /// key window (an accessory app coming forward) there is no news about
    /// where focus is, and before the setting the panel stayed where it was
    /// rather than falling back to the menu-bar display.
    @Test func anActivationWithNoMainScreenChoosesNothing() {
        #expect(DisplayChoice.focusedWindow.screenOnActivation(in: [builtIn, externalMain]) == 2)
        #expect(DisplayChoice.focusedWindow.screenOnActivation(in: [builtInMain, external]) == 1)
        #expect(DisplayChoice.focusedWindow.screenOnActivation(in: [external, builtIn]) == nil)
        #expect(DisplayChoice.focusedWindow.screenOnActivation(in: []) == nil)
    }

    /// Pinned, an activation never names a screen, main or not.
    @Test func aPinnedActivationChoosesNothing() {
        #expect(DisplayChoice.builtIn.screenOnActivation(in: [builtIn, externalMain]) == nil)
        #expect(DisplayChoice.builtIn.screenOnActivation(in: [builtInMain, external]) == nil)
    }

    // MARK: - Persistence

    @Test func anAbsentValueResolvesToTheDefault() {
        #expect(PreferenceKeys.resolveDisplayChoice(nil) == .focusedWindow)
    }

    @Test func storedValuesResolve() {
        for choice in DisplayChoice.allCases {
            #expect(PreferenceKeys.resolveDisplayChoice(choice.rawValue) == choice)
        }
    }

    /// The raw values are what is on disk; renaming a case must not silently
    /// reset everyone's choice.
    @Test func theStoredSpellingsArePinned() {
        #expect(DisplayChoice.focusedWindow.rawValue == "focused-window")
        #expect(DisplayChoice.builtIn.rawValue == "built-in")
        #expect(PreferenceKeys.showOn == "display.showOn")
    }

    @Test func anUnknownOrMistypedValueResolvesToTheDefault() {
        #expect(PreferenceKeys.resolveDisplayChoice("external") == .focusedWindow)
        #expect(PreferenceKeys.resolveDisplayChoice(NSNumber(value: 1)) == .focusedWindow)
    }

    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "com.gcdz.creativenotch.display-choice-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test func aFreshDomainFollowsFocus() {
        #expect(PreferencesStore(defaults: makeIsolatedDefaults()).displayChoice == .focusedWindow)
    }

    @Test func aChoiceSurvivesAReload() {
        let defaults = makeIsolatedDefaults()
        PreferencesStore(defaults: defaults).setDisplayChoice(.builtIn)
        #expect(PreferencesStore(defaults: defaults).displayChoice == .builtIn)
        PreferencesStore(defaults: defaults).setDisplayChoice(.focusedWindow)
        #expect(PreferencesStore(defaults: defaults).displayChoice == .focusedWindow)
    }

    /// A hand-typed value reads as the default and is left in place, the
    /// policy every other key follows.
    @Test func aMistypedValueIsNotRewritten() {
        let defaults = makeIsolatedDefaults()
        defaults.set("laptop", forKey: PreferenceKeys.showOn)
        #expect(PreferencesStore(defaults: defaults).displayChoice == .focusedWindow)
        #expect(defaults.string(forKey: PreferenceKeys.showOn) == "laptop")
    }
}
