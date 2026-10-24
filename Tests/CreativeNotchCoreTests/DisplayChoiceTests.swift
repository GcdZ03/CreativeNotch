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

    private static let dellUUID = "8A3F1E2C-1111-4C6B-9A0E-5D7C2B9E4F10"
    private static let lgUUID = "0C2D4E6F-2222-4A1B-8C3D-9E8F7A6B5C4D"
    private let dell = ScreenDescriptor(id: 4, isBuiltIn: false, isMain: false, uuid: dellUUID, name: "DELL U2720Q")
    private let dellMain = ScreenDescriptor(id: 4, isBuiltIn: false, isMain: true, uuid: dellUUID, name: "DELL U2720Q")
    private let lgMain = ScreenDescriptor(id: 5, isBuiltIn: false, isMain: true, uuid: lgUUID, name: "LG UltraFine")
    private let pinned = DisplayChoice.display(uuid: dellUUID, name: "DELL U2720Q")

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
        for choice in DisplayChoice.standardChoices + [pinned] {
            #expect(choice.screen(in: []) == nil)
        }
    }

    // MARK: - Pinned to a specific display

    @Test func aPinnedDisplayThatIsConnectedWinsWhereverFocusIs() {
        #expect(pinned.screen(in: [builtInMain, dell]) == 4)
        #expect(pinned.screen(in: [builtIn, lgMain, dell]) == 4)
    }

    /// Disconnected, it falls back to the built-in display first -- the one
    /// display a laptop always has -- rather than following focus.
    @Test func aDisconnectedPinFallsBackToTheBuiltIn() {
        #expect(pinned.screen(in: [lgMain, builtIn]) == 1)
    }

    /// Then the main screen, then the first, the order `screen(in:)` already
    /// uses everywhere else.
    @Test func aDisconnectedPinWithNoBuiltInTakesTheMainThenTheFirst() {
        #expect(pinned.screen(in: [external, lgMain]) == 5)
        #expect(pinned.screen(in: [secondExternal, external]) == 3)
    }

    /// Unplugged then plugged back in: nothing is remembered between calls,
    /// so the next screen change simply finds it again.
    @Test func aPinnedDisplayIsReturnedToWhenItReconnects() {
        #expect(pinned.screen(in: [builtInMain, dell]) == 4)
        #expect(pinned.screen(in: [builtInMain]) == 1)
        #expect(pinned.screen(in: [builtInMain, dell]) == 4)
    }

    /// A display that could not report a UUID never matches a pin.
    @Test func aScreenWithNoUUIDNeverMatchesAPin() {
        let anonymous = ScreenDescriptor(id: 9, isBuiltIn: false, isMain: true)
        #expect(pinned.screen(in: [anonymous]) == 9)
        #expect(pinned.screen(in: [builtIn, anonymous]) == 1)
    }

    /// The display id can change across reboots and reconnections; the UUID
    /// is what identifies the display, so a new id for it still matches.
    @Test func aPinMatchesByUUIDNotByDisplayID() {
        let renumbered = ScreenDescriptor(id: 42, isBuiltIn: false, isMain: false, uuid: Self.dellUUID, name: "DELL U2720Q")
        #expect(pinned.screen(in: [builtInMain, renumbered]) == 42)
    }

    // MARK: - The Settings menu

    /// The two general choices first, then one per connected external
    /// display under its current name. The built-in display is already
    /// "Built-in display", so it is not listed twice.
    @Test func theMenuListsEachConnectedExternalDisplay() {
        let options = DisplayChoice.options(for: [builtInMain, dell, lgMain], current: .focusedWindow)
        #expect(options.map(\.choice) == [
            .focusedWindow, .builtIn,
            .display(uuid: Self.dellUUID, name: "DELL U2720Q"),
            .display(uuid: Self.lgUUID, name: "LG UltraFine"),
        ])
        #expect(options.map(\.name) == [nil, nil, "DELL U2720Q", "LG UltraFine"])
        #expect(options.allSatisfy { $0.isConnected })
    }

    /// The pinned display, unplugged, stays in the menu marked as not
    /// connected, so the selection is still visible.
    @Test func theMenuKeepsADisconnectedPinVisible() {
        let options = DisplayChoice.options(for: [builtInMain, lgMain], current: pinned)
        #expect(options.count == 4)
        #expect(options.last == DisplayChoice.Option(choice: pinned, name: "DELL U2720Q", isConnected: false))
    }

    /// Connected, the pin appears once, under the display's current name,
    /// tagged with the stored choice so the menu shows it selected even if
    /// the display has been renamed since it was picked.
    @Test func aConnectedPinIsListedOnceAndSelected() {
        let renamed = DisplayChoice.display(uuid: Self.dellUUID, name: "Old name")
        let options = DisplayChoice.options(for: [builtInMain, dell], current: renamed)
        #expect(options.count == 3)
        #expect(options.last == DisplayChoice.Option(choice: renamed, name: "DELL U2720Q", isConnected: true))
    }

    /// The stored name is what Settings says while the display is unplugged,
    /// so a rename seen while it is connected is taken up: otherwise the
    /// menu would go on naming it by what it was called when it was picked.
    @Test func aConnectedPinTakesUpTheDisplaysCurrentName() {
        let renamed = DisplayChoice.display(uuid: Self.dellUUID, name: "Old name")
        #expect(renamed.refreshingName(from: [builtInMain, dell]) == pinned)
    }

    /// Nothing to take up: the same name, an unplugged pin (whose name is
    /// the only record left), a screen with an empty name, and the general
    /// choices all come back unchanged.
    @Test func refreshingTheNameLeavesEverythingElseAlone() {
        #expect(pinned.refreshingName(from: [builtInMain, dell]) == pinned)
        let renamed = DisplayChoice.display(uuid: Self.dellUUID, name: "Old name")
        #expect(renamed.refreshingName(from: [builtInMain, lgMain]) == renamed)
        let nameless = ScreenDescriptor(id: 4, isBuiltIn: false, isMain: false, uuid: Self.dellUUID, name: "")
        #expect(renamed.refreshingName(from: [nameless]) == renamed)
        #expect(DisplayChoice.builtIn.refreshingName(from: [builtInMain, dell]) == .builtIn)
        #expect(DisplayChoice.focusedWindow.refreshingName(from: [dell]) == .focusedWindow)
    }

    @Test func screensWithoutAUUIDAreLeftOutOfTheMenu() {
        let anonymous = ScreenDescriptor(id: 9, isBuiltIn: false, isMain: true)
        #expect(DisplayChoice.options(for: [anonymous], current: .builtIn).count == 2)
    }

    @Test func noScreensStillOffersTheGeneralChoices() {
        #expect(DisplayChoice.options(for: [], current: .focusedWindow).map(\.choice) == DisplayChoice.standardChoices)
    }

    // MARK: - Activation

    /// Only following focus has any reason to look again when an app comes
    /// forward; pinned, an app switch must not move the notch.
    @Test func onlyFollowingFocusRepositionsOnActivation() {
        #expect(DisplayChoice.focusedWindow.followsActivation)
        #expect(!DisplayChoice.builtIn.followsActivation)
        #expect(!pinned.followsActivation)
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
        #expect(pinned.screenOnActivation(in: [builtInMain, dell]) == nil)
        #expect(pinned.screenOnActivation(in: [builtIn, dellMain]) == nil)
    }

    // MARK: - Persistence

    @Test func anAbsentValueResolvesToTheDefault() {
        #expect(PreferenceKeys.resolveDisplayChoice(nil) == .focusedWindow)
    }

    @Test func storedValuesResolve() {
        for choice in DisplayChoice.standardChoices + [pinned] {
            #expect(PreferenceKeys.resolveDisplayChoice(choice.rawValue) == choice)
        }
    }

    /// The raw values are what is on disk; renaming a case must not silently
    /// reset everyone's choice.
    @Test func theStoredSpellingsArePinned() {
        #expect(DisplayChoice.focusedWindow.rawValue == "focused-window")
        #expect(DisplayChoice.builtIn.rawValue == "built-in")
        #expect(PreferenceKeys.showOn == "display.showOn")
        #expect(pinned.rawValue == "display:\(Self.dellUUID):DELL U2720Q")
    }

    /// The name is only for showing; a colon in it survives, because the
    /// UUID is read up to the first colon after the prefix and has none.
    @Test func aPinnedValueRoundTripsWithAnyName() {
        for name in ["", "Studio Display", "Dell: 27\" (2)"] {
            let choice = DisplayChoice.display(uuid: Self.dellUUID, name: name)
            #expect(PreferenceKeys.resolveDisplayChoice(choice.rawValue) == choice)
        }
    }

    /// `defaults write … display:<uuid>` by hand, without a name, still pins.
    /// A lowercase UUID reads as the uppercase spelling the system reports.
    @Test func aPinnedValueWithoutANameResolves() {
        #expect(PreferenceKeys.resolveDisplayChoice("display:\(Self.dellUUID)") == .display(uuid: Self.dellUUID, name: ""))
        #expect(PreferenceKeys.resolveDisplayChoice("display:\(Self.dellUUID.lowercased()):X") == .display(uuid: Self.dellUUID, name: "X"))
    }

    @Test func aMalformedPinnedValueResolvesToTheDefault() {
        #expect(PreferenceKeys.resolveDisplayChoice("display:") == .focusedWindow)
        #expect(PreferenceKeys.resolveDisplayChoice("display:not-a-uuid:DELL") == .focusedWindow)
        #expect(PreferenceKeys.resolveDisplayChoice("display") == .focusedWindow)
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
        PreferencesStore(defaults: defaults).setDisplayChoice(pinned)
        #expect(PreferencesStore(defaults: defaults).displayChoice == pinned)
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
