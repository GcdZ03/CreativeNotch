import Foundation
import Testing
@testable import CreativeNotchCore

// MARK: - Who may take keyboard focus

/// The tap and the shortcut are a person asking for the panel; they are the
/// only opens that may take the keyboard away from the app underneath.
@Test func anExplicitOpenTakesKeyboardFocusOnEveryTab() {
    for tab in Tab.allCases {
        #expect(PanelFocus.shouldTakeKey(for: .open(tab), openedBy: .tap), "tap, \(tab)")
        #expect(PanelFocus.shouldTakeKey(for: .open(tab), openedBy: .hotKey), "hotKey, \(tab)")
    }
}

/// Hover-open is the one that must never steal keystrokes: a pointer resting
/// on the notch is not someone who has stopped typing in their editor. A
/// swipe, a drop and a bare transition are no request for the keyboard
/// either.
@Test func anAmbientOpenTakesNoKeyboardFocusOffTheTimerTab() {
    for reason in [PanelOpenReason.hover, .swipe, .drop, .unspecified] {
        for tab in Tab.allCases where tab != .timer {
            #expect(!PanelFocus.shouldTakeKey(for: .open(tab), openedBy: reason),
                    "\(reason), \(tab)")
        }
    }
}

/// The timer's custom-minutes field keeps the rule it always had: it needs
/// the keyboard however the panel was opened, or it renders and swallows
/// every keystroke.
@Test func theTimerTabTakesKeyboardFocusHoweverItWasOpened() {
    for reason in [PanelOpenReason.tap, .hotKey, .hover, .swipe, .drop, .unspecified] {
        #expect(PanelFocus.shouldTakeKey(for: .open(.timer), openedBy: reason), "\(reason)")
    }
    #expect(PanelFocus.shouldTakeKey(for: .open(.timer), openedBy: nil))
}

/// Nothing but an open panel takes focus, whatever the reason left behind.
@Test func noClosedOrPeekStateTakesKeyboardFocus() {
    let states: [NotchState] = [
        .closed, .receiving, .peek(.dragTarget),
        .peek(.power(.unplugged(level: 50))),
    ]
    for state in states {
        for reason in [PanelOpenReason.tap, .hotKey, .hover, nil] {
            #expect(!PanelFocus.shouldTakeKey(for: state, openedBy: reason), "\(state)")
        }
    }
}

@Test func onlyTheTapAndTheShortcutAreExplicit() {
    #expect(PanelOpenReason.tap.isExplicit)
    #expect(PanelOpenReason.hotKey.isExplicit)
    #expect(!PanelOpenReason.hover.isExplicit)
    #expect(!PanelOpenReason.swipe.isExplicit)
    #expect(!PanelOpenReason.drop.isExplicit)
    #expect(!PanelOpenReason.unspecified.isExplicit)
}

// MARK: - Keys

private let allTabs: [Tab] = [.shelf, .clipboard, .timer, .power, .camera]

@Test func escapeClosesTheOpenPanel() {
    #expect(PanelKeyboard.action(for: .escape, in: .open(.clipboard), visible: allTabs) == .close)
}

@Test func commandTwoSelectsTheSecondVisibleTab() {
    #expect(PanelKeyboard.action(for: .commandDigit(2), in: .open(.shelf), visible: allTabs)
            == .select(.clipboard))
    #expect(PanelKeyboard.action(for: .commandDigit(1), in: .open(.camera), visible: allTabs)
            == .select(.shelf))
    #expect(PanelKeyboard.action(for: .commandDigit(5), in: .open(.shelf), visible: allTabs)
            == .select(.camera))
}

/// Positions count *visible* tabs, so the shortcut always matches what the
/// tab bar draws: with the clipboard switched off, ⌘2 is the timer.
@Test func aSwitchedOffTabIsSkipped() {
    var preferences = Preferences.allEnabled
    preferences.clipboard = false
    let visible = TabVisibility.visible(enabled: preferences, hasBattery: false)

    #expect(PanelKeyboard.action(for: .commandDigit(2), in: .open(.shelf), visible: visible)
            == .select(.timer))
    #expect(PanelKeyboard.action(for: .commandDigit(3), in: .open(.shelf), visible: visible)
            == .select(.camera))
}

@Test func aDigitBeyondTheVisibleTabsIsIgnored() {
    let visible: [Tab] = [.shelf, .timer]
    #expect(PanelKeyboard.action(for: .commandDigit(3), in: .open(.shelf), visible: visible) == nil)
    #expect(PanelKeyboard.action(for: .commandDigit(9), in: .open(.shelf), visible: visible) == nil)
    #expect(PanelKeyboard.action(for: .commandDigit(0), in: .open(.shelf), visible: visible) == nil)
}

/// Keys only ever act on the open panel: a peek or a drag in flight is not
/// something Esc should tear down, nor ⌘2 blow open.
@Test func keysDoNothingUnlessThePanelIsOpen() {
    for state: NotchState in [.closed, .receiving, .peek(.dragTarget)] {
        #expect(PanelKeyboard.action(for: .escape, in: state, visible: allTabs) == nil)
        #expect(PanelKeyboard.action(for: .commandDigit(1), in: state, visible: allTabs) == nil)
    }
}

// MARK: - Esc and the clipboard search

/// Esc takes back the last thing done first: with a search typed into the
/// clipboard pane it clears the search, and only the next press closes.
@Test func escapeClearsAClipboardSearchBeforeClosing() {
    #expect(PanelKeyboard.action(for: .escape, in: .open(.clipboard), visible: allTabs,
                                 clipboardQuery: "invoice") == .clearSearch)
    #expect(PanelKeyboard.action(for: .escape, in: .open(.clipboard), visible: allTabs,
                                 clipboardQuery: "") == .close)
}

/// A query of spaces filters nothing, so there is nothing for Esc to undo.
@Test func aBlankClipboardSearchDoesNotHoldEscBack() {
    #expect(PanelKeyboard.action(for: .escape, in: .open(.clipboard), visible: allTabs,
                                 clipboardQuery: "   ") == .close)
}

/// The search is the clipboard pane's; on any other tab Esc closes as ever.
@Test func aClipboardSearchDoesNotHoldEscBackOnAnotherTab() {
    #expect(PanelKeyboard.action(for: .escape, in: .open(.shelf), visible: allTabs,
                                 clipboardQuery: "invoice") == .close)
}

/// An empty history shows no search field, so a query left from before a
/// Clear or the last Remove is invisible: Esc closes at once.
@Test func aSearchOverAnEmptyHistoryDoesNotHoldEscBack() {
    #expect(PanelKeyboard.action(for: .escape, in: .open(.clipboard), visible: allTabs,
                                 clipboardQuery: "invoice", clipboardIsEmpty: true) == .close)
    #expect(PanelKeyboard.action(for: .escape, in: .open(.clipboard), visible: allTabs,
                                 clipboardQuery: "invoice", clipboardIsEmpty: false) == .clearSearch)
}

/// ⌘N is not Esc: a typed search never stops the tab shortcuts.
@Test func aClipboardSearchLeavesTheTabShortcutsAlone() {
    #expect(PanelKeyboard.action(for: .commandDigit(1), in: .open(.clipboard), visible: allTabs,
                                 clipboardQuery: "invoice") == .select(.shelf))
}
