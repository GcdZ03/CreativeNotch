import AppKit
import Testing
import CreativeNotchUI

/// `NotchPanel`'s configuration carries the spec's most load-bearing
/// claim: the panel disappears over fullscreen apps *because*
/// `.fullScreenAuxiliary` is absent from `collectionBehavior`, and it
/// never steals focus *because* `canBecomeKey`/`canBecomeMain` stay
/// false. Both are invisible one-line properties with no runtime symptom
/// in a headless test other than their own values, so they are asserted
/// directly.
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

    @Test func panelNeverTakesFocusFromTheFrontmostApp() {
        let panel = makePanel()
        #expect(panel.canBecomeKey == false)
        #expect(panel.canBecomeMain == false)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
    }
}
