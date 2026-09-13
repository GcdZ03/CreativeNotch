import Testing
import CoreGraphics
@testable import CreativeNotchCore

/// The one place the open panel's header and body are split up (spec §3.1).
struct PanelLayoutTests {

    // 14" MacBook Pro-ish: panel 620 wide centred on a 190-wide notch.
    private let notch = Anchor.notch(CGRect(x: 661, y: 950, width: 190, height: 32))
    private let notchPanel = CGRect(x: 446, y: 722, width: 620, height: 260)
    private let pill = Anchor.pill(CGRect(x: 666, y: 942, width: 180, height: 32))
    private let pillPanel = CGRect(x: 446, y: 714, width: 620, height: 260)

    @Test func theHeaderIsAsTallAsTheAnchor() {
        let l = PanelLayout.resolve(anchor: notch, panelFrame: notchPanel, showsMedia: true)
        #expect(l.headerHeight == 32)
    }

    @Test func theEarsAndTheGapSpanThePanelExactly() {
        let l = PanelLayout.resolve(anchor: notch, panelFrame: notchPanel, showsMedia: true)
        #expect(l.leadingEarWidth + l.notchGap + l.trailingEarWidth == notchPanel.width)
        #expect(l.notchGap == 190)
        #expect(l.leadingEarWidth == 215)
        #expect(l.trailingEarWidth == 215)
    }

    /// An off-centre panel (clamped to a screen edge) keeps the gap over
    /// the real notch rather than the panel's middle.
    @Test func theGapFollowsTheNotchNotThePanelCentre() {
        let shifted = CGRect(x: 500, y: 722, width: 620, height: 260)
        let l = PanelLayout.resolve(anchor: notch, panelFrame: shifted, showsMedia: true)
        #expect(l.leadingEarWidth == 161)
        #expect(l.trailingEarWidth == 269)
        #expect(l.leadingEarWidth + l.notchGap + l.trailingEarWidth == shifted.width)
    }

    @Test func aPillHasNoGapAndTwoEqualHalves() {
        let l = PanelLayout.resolve(anchor: pill, panelFrame: pillPanel, showsMedia: true)
        #expect(l.notchGap == 0)
        #expect(l.leadingEarWidth == 310)
        #expect(l.trailingEarWidth == 310)
    }

    @Test func theMediaColumnIsFixedWhenShownAndAbsentWhenNot() {
        #expect(PanelLayout.resolve(anchor: notch, panelFrame: notchPanel, showsMedia: true)
                    .mediaColumnWidth == PanelLayout.mediaColumnWidth)
        #expect(PanelLayout.resolve(anchor: notch, panelFrame: notchPanel, showsMedia: false)
                    .mediaColumnWidth == 0)
    }

    /// Once it is a panel it reads as an island, not as the notch; the
    /// closed radius still approximates the hardware cutout.
    @Test func theOpenPanelRoundsMoreThanTheClosedNotch() {
        #expect(NotchGeometry.panelCornerRadius == 20)
        #expect(NotchGeometry.panelCornerRadius > NotchGeometry.notchCornerRadius)
    }
}
