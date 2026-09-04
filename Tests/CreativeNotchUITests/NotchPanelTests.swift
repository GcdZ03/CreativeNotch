import AppKit
import Testing
import CreativeNotchUI

/// `NotchPanel`'s configuration carries the spec's most load-bearing
/// claim: the panel disappears over fullscreen apps *because*
/// `.fullScreenAuxiliary` is absent from `collectionBehavior`, and it never
/// activates the app *because* of `.nonactivatingPanel` and
/// `canBecomeMain == false`. These are invisible one-line properties with no
/// runtime symptom in a headless test other than their own values, so they
/// are asserted directly.
///
/// `canBecomeKey` was `false` too until the timer's custom-minutes field
/// arrived — the first control in the project that needs a keyboard. The
/// guarantee it was standing in for was never "cannot become key"; it was
/// "never takes the frontmost app's *activation*", and that is
/// `.nonactivatingPanel`'s job. Becoming key costs the frontmost app its
/// insertion point and nothing else, and `AppDelegate.syncKeyWindow` spends
/// even that on one tab only.
@MainActor
struct NotchPanelTests {

    private func makePanel() -> NotchPanel {
        NotchPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 260))
    }

    @Test func panelIsHiddenOverFullscreenApps() {
        // Adding .fullScreenAuxiliary would let the panel float over a
        // fullscreen app, which the design explicitly rejects.
        #expect(!makePanel().collectionBehavior.contains(.fullScreenAuxiliary))
    }

    @Test func panelFollowsAcrossSpacesWithoutJoiningTheWindowCycle() {
        #expect(makePanel().collectionBehavior == [.canJoinAllSpaces, .stationary, .ignoresCycle])
    }

    /// The guarantee that actually matters, and the one that has not
    /// changed: opening the notch never makes CreativeNotch the active
    /// application. `.nonactivatingPanel` is what delivers it — drop that
    /// flag and every panel open would pull the menu bar out from under
    /// whatever you were using.
    @Test func panelNeverActivatesTheApp() {
        let panel = makePanel()
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.canBecomeMain == false)
    }

    /// Key is permitted, and deliberately so: without it the timer's
    /// custom-minutes field renders and then swallows every keystroke,
    /// which is exactly what shipped once.
    ///
    /// This asserts the capability only. *When* it is spent is
    /// `AppDelegate.syncKeyWindow`'s decision and is tested there —
    /// splitting the two is what keeps this from becoming a test that
    /// merely restates the implementation.
    @Test func panelCanTakeKeyboardFocusForTheOneControlThatNeedsIt() {
        #expect(makePanel().canBecomeKey)
    }

    /// The panel is black on every system theme, so its appearance must be
    /// dark on every system theme too.
    ///
    /// Without this, AppKit resolves stock controls' semantic colours
    /// against the *user's* setting: under Light appearance a `.bordered`
    /// button's label is near-black, drawn on this panel's black
    /// background. That shipped — Pause and Cancel were rendered,
    /// hit-testable and invisible.
    ///
    /// Asserted here rather than left to a rendering test because
    /// `ImageRenderer` has no window, and therefore no appearance for a
    /// semantic colour to resolve against. The bug is unreachable from the
    /// only kind of test that draws anything.
    @Test func panelForcesDarkAppearanceSoStockControlsAreLegible() {
        #expect(makePanel().appearance?.name == .darkAqua)
    }
}
