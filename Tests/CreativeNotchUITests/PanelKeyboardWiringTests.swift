import AppKit
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// Keyboard control of the open panel, from the app's side: which opens take
/// focus, and what Esc and ⌘1…⌘N do once keys arrive.
///
/// The rules themselves are pure and pinned in Core (`PanelKeyboardTests`).
/// This suite proves the assembly — that each route into the panel records
/// the reason the rule reads, and that a key reaches the state funnel.
@MainActor
struct PanelKeyboardWiringTests {

    /// A delegate whose key-taking is counted instead of performed. A
    /// headless suite cannot make an offscreen panel key, so `makeKey` would
    /// prove nothing.
    private func makeDelegate() -> (AppDelegate, () -> Int) {
        let d = NotchedDelegate.make()
        var taken = 0
        d.takeKey = { taken += 1 }
        return (d, { taken })
    }

    // MARK: - The open reason, recorded in the funnel

    @Test func theNotchTapRecordsAnExplicitOpen() {
        let (d, _) = makeDelegate()
        NotchRootView.handleTap(app: d.state)
        #expect(d.state.openReason == .tap)
    }

    @Test func theShortcutRecordsAnExplicitOpen() {
        let (d, _) = makeDelegate()
        d.toggleFromHotKey()
        #expect(d.state.openReason == .hotKey)
    }

    @Test func aHoverOpenRecordsHover() {
        let (d, _) = makeDelegate()
        d.state.onSetHoverBehaviour?(HoverBehaviour(opensOnHover: true, openDelay: 0.6))
        d.hoverView?.onDwell()
        #expect(d.state.openReason == .hover)
    }

    /// The reason belongs to the open, not to the tab: switching tabs keeps
    /// it, and leaving `.open` clears it so a later ambient open cannot
    /// inherit a stale tap.
    @Test func theReasonSurvivesATabSwitchAndClearsOnClose() {
        let (d, _) = makeDelegate()
        NotchRootView.handleTap(app: d.state)
        d.state.transition(to: .open(.clipboard))
        #expect(d.state.openReason == .tap)

        d.state.transition(to: .closed)
        #expect(d.state.openReason == nil)

        d.state.transition(to: .open(.shelf))
        #expect(d.state.openReason == .unspecified)
    }

    // MARK: - Taking focus

    @Test func shouldTakeKeyForEachOpenReason() {
        #expect(AppDelegate.shouldTakeKey(for: .open(.shelf), openedBy: .tap))
        #expect(AppDelegate.shouldTakeKey(for: .open(.shelf), openedBy: .hotKey))
        #expect(!AppDelegate.shouldTakeKey(for: .open(.shelf), openedBy: .hover))
        #expect(!AppDelegate.shouldTakeKey(for: .open(.shelf), openedBy: .swipe))
        #expect(!AppDelegate.shouldTakeKey(for: .open(.shelf), openedBy: .drop))
        #expect(!AppDelegate.shouldTakeKey(for: .open(.shelf), openedBy: .unspecified))
    }

    @Test func theShortcutTakesKeyboardFocus() {
        let (d, taken) = makeDelegate()
        d.toggleFromHotKey()
        #expect(taken() == 1)
    }

    @Test func theNotchTapTakesKeyboardFocus() {
        let (d, taken) = makeDelegate()
        NotchRootView.handleTap(app: d.state)
        #expect(taken() == 1)
    }

    /// The one that matters most: a pointer resting on the notch must never
    /// take the keystrokes meant for the editor underneath.
    @Test func aHoverOpenNeverTakesKeyboardFocus() {
        let (d, taken) = makeDelegate()
        d.state.onSetHoverBehaviour?(HoverBehaviour(opensOnHover: true, openDelay: 0.6))
        d.hoverView?.onDwell()
        #expect(d.state.state == .open(.shelf))
        #expect(taken() == 0)
    }

    /// An explicit open still gives focus back once the panel leaves `.open`.
    @Test func closingAnExplicitOpenGivesFocusBack() {
        let (d, _) = makeDelegate()
        var isKey = false
        var given = 0
        d.panelIsKey = { _ in isKey }
        d.relinquishKey = { given += 1; isKey = false }

        d.toggleFromHotKey()
        isKey = true
        d.toggleFromHotKey()

        #expect(d.state.state == .closed)
        #expect(given == 1)
    }

    // MARK: - Keys, through the funnel

    @Test func escapeClosesTheOpenPanel() {
        let (d, _) = makeDelegate()
        d.toggleFromHotKey()
        #expect(d.handlePanelKey(.escape))
        #expect(d.state.state == .closed)
    }

    @Test func commandTwoSwitchesToTheSecondVisibleTab() {
        let (d, _) = makeDelegate()
        d.toggleFromHotKey()
        #expect(d.handlePanelKey(.commandDigit(2)))
        #expect(d.state.state == .open(.clipboard))
    }

    @Test func aSwitchedOffTabIsSkipped() {
        let (d, _) = makeDelegate()
        d.switchboard.setEnabled(false, for: .clipboard, persist: false)
        d.toggleFromHotKey()
        #expect(d.handlePanelKey(.commandDigit(2)))
        #expect(d.state.state == .open(.timer))
    }

    /// Beyond the last visible tab the key is not ours: it is declined, so
    /// AppKit passes it on, and the panel stays where it was.
    @Test func aDigitBeyondTheVisibleTabsIsIgnored() {
        let (d, _) = makeDelegate()
        d.toggleFromHotKey()
        #expect(!d.handlePanelKey(.commandDigit(9)))
        #expect(d.state.state == .open(.shelf))
    }

    @Test func keysAreDeclinedWhileClosed() {
        let (d, _) = makeDelegate()
        #expect(!d.handlePanelKey(.escape))
        #expect(!d.handlePanelKey(.commandDigit(1)))
        #expect(d.state.state == .closed)
    }

    /// The installed panel routes its keys to the delegate, not to a copy of
    /// the rule.
    @Test func theInstalledPanelForwardsKeysToTheDelegate() throws {
        let (d, _) = makeDelegate()
        d.toggleFromHotKey()
        let panel = try #require(d.panel)
        let escape = try #require(NotchPanelKeyTests.event(keyCode: 53, characters: "\u{1b}", modifiers: []))
        panel.keyDown(with: escape)
        #expect(d.state.state == .closed)
    }
}

/// Decoding `NSEvent`s into `PanelKey`s, and the panel's three entry points.
@MainActor
struct NotchPanelKeyTests {

    static func event(keyCode: UInt16, characters: String, modifiers: NSEvent.ModifierFlags) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode
        )
    }

    @Test func escapeDecodes() {
        #expect(NotchPanel.panelKey(keyCode: 53, modifiers: []) == .escape)
    }

    /// The number row by key code, so ⌘2 is the same physical key on every
    /// layout — on AZERTY the unshifted character there is "é", not "2".
    @Test func commandDigitsDecodeByPosition() {
        let codes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
        for (index, code) in codes.enumerated() {
            #expect(NotchPanel.panelKey(keyCode: code, modifiers: .command) == .commandDigit(index + 1))
        }
    }

    /// Plain digits are typing (the timer's minutes field), and ⌘⇧2 or ⌥⌘2
    /// belong to someone else.
    @Test func digitsWithoutExactlyCommandAreNotOurs() {
        #expect(NotchPanel.panelKey(keyCode: 19, modifiers: []) == nil)
        #expect(NotchPanel.panelKey(keyCode: 19, modifiers: [.command, .shift]) == nil)
        #expect(NotchPanel.panelKey(keyCode: 19, modifiers: [.command, .option]) == nil)
        // ⌘0 is not a tab.
        #expect(NotchPanel.panelKey(keyCode: 29, modifiers: .command) == nil)
        // Caps Lock is a state, not a chord.
        #expect(NotchPanel.panelKey(keyCode: 19, modifiers: [.command, .capsLock]) == .commandDigit(2))
    }

    @Test func aCommandDigitIsAKeyEquivalent() throws {
        let panel = NotchPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 260))
        var received: [PanelKey] = []
        panel.onPanelKey = { received.append($0); return true }
        let event = try #require(Self.event(keyCode: 19, characters: "2", modifiers: .command))

        #expect(panel.performKeyEquivalent(with: event))
        #expect(received == [.commandDigit(2)])
    }

    /// Declined keys are passed on, so the panel never swallows a chord it
    /// has no use for.
    @Test func aDeclinedKeyEquivalentIsPassedOn() throws {
        let panel = NotchPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 260))
        panel.onPanelKey = { _ in false }
        let event = try #require(Self.event(keyCode: 25, characters: "9", modifiers: .command))
        #expect(!panel.performKeyEquivalent(with: event))
    }

    /// Esc reaches the window either as a raw key-down or, when a text field
    /// is editing, as `cancelOperation(_:)` sent up the responder chain.
    /// Both land on the same callback.
    @Test func escapeArrivesByEitherRoute() throws {
        let panel = NotchPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 260))
        var received: [PanelKey] = []
        panel.onPanelKey = { received.append($0); return true }

        panel.keyDown(with: try #require(Self.event(keyCode: 53, characters: "\u{1b}", modifiers: [])))
        panel.cancelOperation(nil)

        #expect(received == [.escape, .escape])
    }
}
