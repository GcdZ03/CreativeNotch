import AppKit
import Foundation
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// The welcome card's wiring: the flag is loaded at install, every way of
/// dismissing it persists, and the menu's "Show Welcome Again" brings it
/// back. The decisions themselves are `WelcomeCardTests`, in Core.
@MainActor
struct WelcomeWiringTests {

    private func makeDelegate(defaults: UserDefaults = TestDefaults.isolated("welcome")) -> AppDelegate {
        let delegate = NotchedDelegate.make()
        delegate.preferencesDefaults = defaults
        delegate.install(metrics: NotchedDelegate.metrics)
        // Never the real Settings window from a test.
        delegate.presentPreferences = { _ in }
        return delegate
    }

    /// A bare `AppState` — every rendering test's — has no card, so no
    /// existing render changes underneath it.
    @Test func aBareStateHasNoCard() {
        let state = AppState()
        state.transition(to: .open(.shelf))
        #expect(!state.showsWelcome)
    }

    @Test func aFreshInstallShowsItTheFirstTimeThePanelOpens() {
        let d = makeDelegate()
        #expect(!d.state.showsWelcome, "shown while closed")
        #expect(d.openPanel())
        #expect(d.state.showsWelcome)
    }

    @Test func gotItPersistsAndHidesIt() {
        let defaults = TestDefaults.isolated("welcome")
        let d = makeDelegate(defaults: defaults)
        d.openPanel()

        d.state.setWelcomeSeen(true)

        #expect(!d.state.showsWelcome)
        #expect(PreferencesStore(defaults: defaults).hasSeenWelcome)
    }

    /// Closing the panel after the card was on screen counts as reading it.
    @Test func closingThePanelPersistsIt() {
        let defaults = TestDefaults.isolated("welcome")
        let d = makeDelegate(defaults: defaults)
        d.openPanel()

        d.state.transition(to: .closed)

        #expect(PreferencesStore(defaults: defaults).hasSeenWelcome)
        d.openPanel()
        #expect(!d.state.showsWelcome, "it came back on the second open")
    }

    @Test func switchingTabsKeepsIt() {
        let defaults = TestDefaults.isolated("welcome")
        let d = makeDelegate(defaults: defaults)
        d.openPanel()

        d.state.transition(to: .open(.clipboard))

        #expect(d.state.showsWelcome)
        #expect(!PreferencesStore(defaults: defaults).hasSeenWelcome)
    }

    /// A relaunch reads the flag back: install loads it, it does not cache.
    @Test func aSeenCardStaysGoneAcrossALaunch() {
        let defaults = TestDefaults.isolated("welcome")
        PreferencesStore(defaults: defaults).setHasSeenWelcome(true)
        let d = makeDelegate(defaults: defaults)
        d.openPanel()
        #expect(!d.state.showsWelcome)
    }

    /// "Set Shortcut…" dismisses the card, closes the panel — Settings is an
    /// activating window — and asks for Settings on the shortcut row.
    @Test func setShortcutOpensSettingsOnTheShortcutRow() {
        let defaults = TestDefaults.isolated("welcome")
        let d = makeDelegate(defaults: defaults)
        var asked: [PreferencesSection?] = []
        d.presentPreferences = { asked.append($0) }
        d.openPanel()

        d.state.onWelcomeSetShortcut?()

        #expect(asked == [.shortcut])
        #expect(d.state.state == .closed)
        #expect(PreferencesStore(defaults: defaults).hasSeenWelcome)
    }

    /// The gear asks for Settings with nothing highlighted.
    @Test func theGearHighlightsNothing() {
        let d = makeDelegate()
        var asked: [PreferencesSection?] = []
        d.presentPreferences = { asked.append($0) }
        d.state.onOpenSettings?()
        #expect(asked == [nil])
    }

    @Test func showWelcomeAgainClearsTheFlagAndOpensThePanelOnIt() {
        let defaults = TestDefaults.isolated("welcome")
        PreferencesStore(defaults: defaults).setHasSeenWelcome(true)
        let d = makeDelegate(defaults: defaults)

        d.showWelcomeAgain()

        #expect(!PreferencesStore(defaults: defaults).hasSeenWelcome)
        #expect(d.state.showsWelcome)
    }

    @Test func theMenuOffersShowWelcomeAgain() throws {
        var shown = 0
        let menuBar = MenuBarController(
            onShowPreferences: {},
            onClearShelf: {},
            shelfCount: { 0 },
            onClearClipboard: {},
            clipboardCount: { 0 },
            onShowWelcome: { shown += 1 }
        )
        menuBar.showWelcome()
        #expect(shown == 1)
    }

    // MARK: - Drawn

    /// The card covers the body and its buttons fit inside the panel: the
    /// prominent "Got it" is a white capsule at the bottom-right of the body,
    /// where no pane draws anything that bright with the shelf empty.
    /// `PanelRenderingTests`' geometry and ink measure, so the numbers
    /// compare with that suite's.
    @Test func theCardDrawsItsButtonsInsideThePanel() throws {
        let corner = CGRect(x: 520, y: 205, width: 90, height: 45)

        let without = PanelRenderingTests.state(media: false)
        without.transition(to: .open(.timer))
        let plain = try #require(PanelRenderingTests.bitmap(without))

        let with = PanelRenderingTests.state(media: false)
        with.welcomeSeen = false
        with.transition(to: .open(.timer))
        let welcomed = try #require(PanelRenderingTests.bitmap(with))

        #expect(PanelRenderingTests.ink(welcomed, in: corner) > 0.15,
                "no Got it button at the bottom-right of the body")
        #expect(PanelRenderingTests.ink(welcomed, in: corner) > PanelRenderingTests.ink(plain, in: corner))
        // The header is not covered: the tabs stay there to try.
        #expect(PanelRenderingTests.ink(welcomed, in: CGRect(x: 0, y: 2, width: 215, height: 28)) > 0.01)
    }

    // MARK: - Settings

    /// The controller carries the request to the view, which scrolls to it
    /// and highlights the row.
    @Test func settingsRemembersWhichRowToHighlight() {
        let d = makeDelegate()
        let controller = PreferencesController(
            switchboard: d.switchboard,
            state: d.state,
            launchAtLogin: d.launchAtLogin,
            presenter: { _ in }
        )
        controller.show(highlighting: .shortcut)
        #expect(controller.highlight.section == .shortcut)
        let first = controller.highlight.request

        // A second ask re-triggers the scroll even when the row is the same.
        controller.show(highlighting: .shortcut)
        let second = controller.highlight.request
        #expect(second != first)

        // A plain open asks for nothing new.
        controller.show()
        #expect(controller.highlight.request == second)
    }
}
