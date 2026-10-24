import AppKit
import Foundation
import SwiftUI
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
        #expect(d.openPanel(openedBy: .tap))
        #expect(d.state.showsWelcome)
    }

    @Test func gotItPersistsAndHidesIt() {
        let defaults = TestDefaults.isolated("welcome")
        let d = makeDelegate(defaults: defaults)
        d.openPanel(openedBy: .tap)

        d.state.setWelcomeSeen(true)

        #expect(!d.state.showsWelcome)
        #expect(PreferencesStore(defaults: defaults).hasSeenWelcome)
    }

    /// Closing the panel after the card was on screen counts as reading it.
    @Test func closingThePanelPersistsIt() {
        let defaults = TestDefaults.isolated("welcome")
        let d = makeDelegate(defaults: defaults)
        d.openPanel(openedBy: .tap)

        d.state.transition(to: .closed)

        #expect(PreferencesStore(defaults: defaults).hasSeenWelcome)
        d.openPanel(openedBy: .tap)
        #expect(!d.state.showsWelcome, "it came back on the second open")
    }

    /// The card's last line points at the tabs. Trying one shows that tab,
    /// and counts as having read the card — kept, it would cover every tab's
    /// body and make the tabs look broken.
    @Test func switchingTabsShowsTheTabAndDismissesIt() {
        let defaults = TestDefaults.isolated("welcome")
        let d = makeDelegate(defaults: defaults)
        d.openPanel(openedBy: .tap)

        d.state.transition(to: .open(.clipboard))

        #expect(!d.state.showsWelcome)
        #expect(PreferencesStore(defaults: defaults).hasSeenWelcome)
    }

    /// ⌘N is a tab switch like a click.
    @Test func aCommandDigitTabSwitchDismissesItToo() {
        let defaults = TestDefaults.isolated("welcome")
        let d = makeDelegate(defaults: defaults)
        d.toggleFromHotKey()
        #expect(d.state.showsWelcome)

        #expect(d.handlePanelKey(.commandDigit(2)))

        #expect(!d.state.showsWelcome)
        #expect(PreferencesStore(defaults: defaults).hasSeenWelcome)
    }

    // MARK: - Ambient opens neither show nor spend it

    /// A pointer crossing the notch with open-on-hover on: no card, and
    /// leaving does not mark it seen. The next asked-for open shows it.
    @Test func aHoverOpenNeitherShowsNorSpendsIt() {
        let defaults = TestDefaults.isolated("welcome")
        let d = makeDelegate(defaults: defaults)
        d.state.onSetHoverBehaviour?(HoverBehaviour(opensOnHover: true, openDelay: 0.6))
        d.hoverView?.onDwell()
        #expect(d.state.state == .open(.shelf))
        #expect(!d.state.showsWelcome, "shown on a hover-open")

        d.state.transition(to: .closed)

        #expect(!PreferencesStore(defaults: defaults).hasSeenWelcome)
        d.openPanel(openedBy: .tap)
        #expect(d.state.showsWelcome)
    }

    @Test func aSwipeOpenDoesNotShowIt() {
        let d = makeDelegate()
        d.openPanel(openedBy: .swipe)
        #expect(!d.state.showsWelcome)
    }

    /// A first drop opens the shelf on the file just dropped, not on a card
    /// that covers it — and the card is still unread afterwards.
    @Test func aDropOpenShowsTheFileNotTheCard() throws {
        let defaults = TestDefaults.isolated("welcome")
        let d = makeDelegate(defaults: defaults)
        let container = try #require(d.panel?.contentView as? PassthroughContainer)

        container.onDragEntered()
        #expect(container.onDrop([.text("stashed")]))

        #expect(d.state.state == .open(.shelf))
        #expect(!d.state.showsWelcome)
        d.state.transition(to: .closed)
        #expect(!PreferencesStore(defaults: defaults).hasSeenWelcome)
    }

    /// A drag arriving over the open panel is someone dragging, not someone
    /// who read the card: it yields to the drop target unspent.
    @Test func aDragIntoTheOpenPanelDoesNotSpendIt() {
        let defaults = TestDefaults.isolated("welcome")
        let d = makeDelegate(defaults: defaults)
        d.openPanel(openedBy: .tap)
        #expect(d.state.showsWelcome)

        d.state.transition(to: .receiving)

        #expect(!d.state.showsWelcome)
        #expect(!PreferencesStore(defaults: defaults).hasSeenWelcome)
    }

    // MARK: - Never over the camera

    /// Showing the camera tab starts the camera; the card must not cover a
    /// live preview and its controls. Switching to it dismisses the card.
    @Test func switchingToTheCameraTabTakesTheCardAway() throws {
        let defaults = TestDefaults.isolated("welcome")
        let d = makeDelegate(defaults: defaults)
        d.openPanel(openedBy: .tap)
        #expect(d.state.showsWelcome)

        d.state.transition(to: .open(.camera))

        #expect(!d.state.showsWelcome)
        #expect(PreferencesStore(defaults: defaults).hasSeenWelcome)
    }

    /// An asked-for open straight onto the camera shows no card, and so
    /// spends none.
    @Test func anOpenOntoTheCameraTabNeitherShowsNorSpendsIt() {
        let defaults = TestDefaults.isolated("welcome")
        let d = makeDelegate(defaults: defaults)
        d.state.retarget(lastOpenTab: .camera)
        d.openPanel(openedBy: .tap)
        #expect(d.state.state == .open(.camera))
        #expect(!d.state.showsWelcome)

        d.state.transition(to: .closed)
        #expect(!PreferencesStore(defaults: defaults).hasSeenWelcome)
    }

    /// A relaunch reads the flag back: install loads it, it does not cache.
    @Test func aSeenCardStaysGoneAcrossALaunch() {
        let defaults = TestDefaults.isolated("welcome")
        PreferencesStore(defaults: defaults).setHasSeenWelcome(true)
        let d = makeDelegate(defaults: defaults)
        d.openPanel(openedBy: .tap)
        #expect(!d.state.showsWelcome)
    }

    /// "Set Shortcut…" dismisses the card, closes the panel — Settings is an
    /// activating window — and asks for Settings on the shortcut row.
    @Test func setShortcutOpensSettingsOnTheShortcutRow() {
        let defaults = TestDefaults.isolated("welcome")
        let d = makeDelegate(defaults: defaults)
        var asked: [PreferencesSection?] = []
        d.presentPreferences = { asked.append($0) }
        d.openPanel(openedBy: .tap)

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

    /// A menu click is asked for: it opens as `.tap`, so the panel takes the
    /// keyboard and Esc dismisses the card.
    @Test func showWelcomeAgainClearsTheFlagAndOpensThePanelOnIt() {
        let defaults = TestDefaults.isolated("welcome")
        PreferencesStore(defaults: defaults).setHasSeenWelcome(true)
        let d = makeDelegate(defaults: defaults)
        var taken = 0
        d.takeKey = { taken += 1 }

        d.showWelcomeAgain()

        #expect(!PreferencesStore(defaults: defaults).hasSeenWelcome)
        #expect(d.state.showsWelcome)
        #expect(d.state.openReason == .tap)
        #expect(taken == 1)
        #expect(d.handlePanelKey(.escape))
        #expect(d.state.state == .closed)
    }

    /// Not onto the camera, where the card never shows: that would start the
    /// camera and show no welcome.
    @Test func showWelcomeAgainAvoidsTheCameraTab() throws {
        let defaults = TestDefaults.isolated("welcome")
        PreferencesStore(defaults: defaults).setHasSeenWelcome(true)
        let d = makeDelegate(defaults: defaults)
        let camera = try #require(d.camera)
        camera.authorizationStatus = { .authorized }
        d.state.retarget(lastOpenTab: .camera)

        d.showWelcomeAgain()

        #expect(d.state.state == .open(.shelf))
        #expect(d.state.showsWelcome)
        #expect(camera.shouldRun == false)
    }

    /// With every tab switched off there is no panel to open: it declines,
    /// like every other opener, and the flag stays cleared for later.
    @Test func showWelcomeAgainDeclinesWithNoVisibleTab() {
        let defaults = TestDefaults.isolated("welcome")
        PreferencesStore(defaults: defaults).setHasSeenWelcome(true)
        let d = makeDelegate(defaults: defaults)
        for module in [ModuleID.shelf, .clipboard, .timer, .power, .camera] {
            d.switchboard.setEnabled(false, for: module, persist: false)
        }

        d.showWelcomeAgain()

        #expect(d.state.state == .closed)
        #expect(!PreferencesStore(defaults: defaults).hasSeenWelcome)
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
        with.transition(to: .open(.timer), openedBy: .tap)
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

    /// **On the very first open the form has not laid out yet**, and a
    /// `scrollTo` issued then lands nowhere: the Shortcut row is at the
    /// bottom of a form that has no rows to scroll between yet. The request
    /// waits for the form's first layout and is acted on then; once laid
    /// out, later asks scroll straight away.
    @Test func theScrollWaitsForTheFormsFirstLayout() {
        let highlight = PreferencesHighlight()
        highlight.ask(for: .shortcut)
        #expect(highlight.scrollTarget == nil, "scrolled a form that has not laid out")
        let beforeLayout = highlight.scrollKey

        highlight.formDidLayOut()
        #expect(highlight.scrollTarget == .shortcut)
        #expect(highlight.scrollKey != beforeLayout, "the scroll task would not re-run")

        // A later layout pass is not a new request.
        let laidOut = highlight.scrollKey
        highlight.formDidLayOut()
        #expect(highlight.scrollKey == laidOut)

        // And with the form up, an ask scrolls at once.
        highlight.fade(request: highlight.request)
        #expect(highlight.scrollTarget == nil)
        highlight.ask(for: .shortcut)
        #expect(highlight.scrollTarget == .shortcut)
    }

    /// The real view reports its layout: hosted offscreen and laid out,
    /// the form tells the highlight it is ready.
    @Test func theFormReportsItsLayout() {
        let d = makeDelegate()
        let controller = PreferencesController(
            switchboard: d.switchboard,
            state: d.state,
            launchAtLogin: d.launchAtLogin,
            presenter: { _ in }
        )
        controller.show(highlighting: .shortcut)
        let host = NSHostingView(rootView: PreferencesView(controller: controller))
        host.frame = CGRect(x: 0, y: 0, width: 520, height: 600)
        host.layoutSubtreeIfNeeded()
        #expect(controller.highlight.scrollTarget == .shortcut)
    }
}
