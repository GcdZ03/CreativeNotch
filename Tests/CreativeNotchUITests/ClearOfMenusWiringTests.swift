import AppKit
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// "Keep clear of app menus" from the app's side (2026-10-26): when the
/// frontmost app's menus are read, and where the pill goes with them.
///
/// The reader is a fake, so nothing here touches Accessibility or prompts;
/// the arithmetic behind the real reader is pinned in `AppMenusTests`, and
/// where the pill goes for a given reach in `NotchGeometryTests`.
@MainActor
struct ClearOfMenusWiringTests {

    /// A portrait display with no notch: centre 540, and an app's menus can
    /// reach past it.
    private static let portrait = ScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 1080, height: 1920),
        safeAreaTopInset: 0, auxiliaryTopLeftWidth: 0, auxiliaryTopRightWidth: 0, menuBarHeight: 30
    )
    private static let centred: CGFloat = 540
    /// pid 42's menus end at 700: the widest closed pill (68) starts 12
    /// past them, so its centre is 700 + 12 + 34.
    private static let clear: CGFloat = 746
    private static let longMenus: pid_t = 42
    private static let shortMenus: pid_t = 43
    private static let noMenus: pid_t = 99

    final class FakeReader: AppMenuReader {
        var isTrusted = true
        var ends: [pid_t: CGFloat] = [
            ClearOfMenusWiringTests.longMenus: 700, ClearOfMenusWiringTests.shortMenus: 100,
        ]
        var reads: [pid_t] = []
        var trustRequests = 0
        func requestTrust() { trustRequests += 1 }
        func menusEnd(of pid: pid_t) -> CGFloat? {
            reads.append(pid)
            return ends[pid]
        }
    }

    /// A delegate on the portrait display, pinned by default so that an
    /// activation places the panel again only for the menus.
    private func make(
        choice: DisplayChoice = .builtIn, trusted: Bool = true, on: Bool = true
    ) -> (AppDelegate, FakeReader) {
        let d = NotchedDelegate.make()
        let reader = FakeReader()
        reader.isTrusted = trusted
        d.appMenuReader = reader
        d.screenMetrics = { _ in Self.portrait }
        d.activationScreenMetrics = { _ in Self.portrait }
        d.state.onSetDisplayChoice?(choice)
        if on { d.state.onSetPillClearsMenus?(true) }
        reader.reads.removeAll()
        reader.trustRequests = 0
        return (d, reader)
    }

    // MARK: - Off

    /// Off, the default: an app switch reads nothing and the pill stays
    /// centred, as before the setting.
    @Test func offAnActivationReadsNoMenus() {
        let (d, reader) = make(on: false)
        d.activeApplicationDidChange(pid: Self.longMenus)
        #expect(reader.reads.isEmpty)
        #expect(d.currentAnchor.rect.midX == Self.centred)
        #expect(d.state.pillClearsMenus == false)
    }

    // MARK: - On

    /// The reported case: an app whose menus reach under the pill comes
    /// forward, and the pill moves clear of them -- pinned or not.
    @Test func anAppWithLongMenusMovesThePillClear() {
        let (d, reader) = make()
        d.activeApplicationDidChange(pid: Self.longMenus)
        #expect(reader.reads == [Self.longMenus])
        #expect(d.currentAnchor.rect.midX == Self.clear)
    }

    @Test func followingFocusTheActivationPlacesItClearToo() {
        let (d, _) = make(choice: .focusedWindow)
        d.activeApplicationDidChange(pid: Self.longMenus)
        #expect(d.currentAnchor.rect.midX == Self.clear)
    }

    /// The next app's menus are short: back to the centre.
    @Test func anAppWithShortMenusBringsItBack() {
        let (d, _) = make()
        d.activeApplicationDidChange(pid: Self.longMenus)
        d.activeApplicationDidChange(pid: Self.shortMenus)
        #expect(d.currentAnchor.rect.midX == Self.centred)
    }

    /// An app with no menu bar to read -- an accessory app, or one that did
    /// not answer -- says nothing about where the menus are, so the pill
    /// stays where the last answer put it.
    @Test func anAppWithNoMenusToReadLeavesThePillWhereItWas() {
        let (d, _) = make()
        d.activeApplicationDidChange(pid: Self.longMenus)
        d.activeApplicationDidChange(pid: Self.noMenus)
        #expect(d.currentAnchor.rect.midX == Self.clear)
    }

    /// Settings coming forward is this app activating: it has no menus, and
    /// the pill must not move under the switch being flipped.
    @Test func thisAppComingForwardReadsNothing() {
        let (d, reader) = make()
        d.activeApplicationDidChange(pid: ProcessInfo.processInfo.processIdentifier)
        #expect(reader.reads.isEmpty)
    }

    /// Switched off, the pill goes back to the centre at once, and stays
    /// off across a relaunch.
    @Test func switchingOffCentresThePillAndIsSaved() {
        let (d, _) = make()
        d.activeApplicationDidChange(pid: Self.longMenus)
        d.state.onSetPillClearsMenus?(false)
        #expect(d.currentAnchor.rect.midX == Self.centred)
        #expect(d.state.pillClearsMenus == false)
        #expect(PreferencesStore(defaults: d.preferencesDefaults).pillClearsMenus == false)
    }

    @Test func switchingOnIsSaved() {
        let (d, _) = make()
        #expect(d.state.pillClearsMenus)
        #expect(PreferencesStore(defaults: d.preferencesDefaults).pillClearsMenus)
    }

    /// Switched on while Settings is in front, the app to keep clear of is
    /// the one that was in front before: measured at once, not on the next
    /// switch.
    @Test func switchingOnMeasuresTheAppThatWasInFront() {
        let (d, reader) = make(on: false)
        d.activeApplicationDidChange(pid: Self.longMenus)
        d.state.onSetPillClearsMenus?(true)
        #expect(reader.reads == [Self.longMenus])
        #expect(d.currentAnchor.rect.midX == Self.clear)
    }

    // MARK: - Accessibility access

    /// Switching on is what asks for Accessibility access, and only when
    /// macOS has not already given it.
    @Test func switchingOnAsksForAccessOnlyWithoutIt() {
        let (untrusted, without) = make(trusted: false, on: false)
        let (trusted, with) = make(on: false)
        untrusted.state.onSetPillClearsMenus?(true)
        trusted.state.onSetPillClearsMenus?(true)
        #expect(without.trustRequests == 1)
        #expect(with.trustRequests == 0)
        #expect(untrusted.state.accessibilityTrusted == false)
        #expect(trusted.state.accessibilityTrusted)
    }

    /// On without access, an app switch reads nothing -- and once access is
    /// allowed in System Settings, the next switch does, with no relaunch.
    @Test func accessAllowedLaterTakesEffectOnTheNextSwitch() {
        let (d, reader) = make(trusted: false)
        d.activeApplicationDidChange(pid: Self.longMenus)
        #expect(reader.reads.isEmpty)
        #expect(d.currentAnchor.rect.midX == Self.centred)

        reader.isTrusted = true
        d.activeApplicationDidChange(pid: Self.longMenus)
        #expect(d.currentAnchor.rect.midX == Self.clear)
        #expect(d.state.accessibilityTrusted)
    }

    /// Settings reads the grant when it is shown, so its warning follows a
    /// change made in System Settings.
    @Test func refreshingReadsTheGrantAgain() {
        let (d, reader) = make(trusted: false)
        #expect(d.state.accessibilityTrusted == false)
        reader.isTrusted = true
        d.state.onRefreshAccessibility?()
        #expect(d.state.accessibilityTrusted)
    }
}
