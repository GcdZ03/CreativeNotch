import Testing
import CoreGraphics
@testable import CreativeNotchCore

private let anchor = Anchor.notch(
    CGRect(x: 620, y: 918, width: 230, height: 38)
)
private let panel = CGRect(x: 415, y: 696, width: 620, height: 260)

@Test func closedVisibleRectMatchesTheAnchorExactly() {
    let r = NotchShape.visibleRect(presentation: .closed, anchor: anchor, panelFrame: panel)
    #expect(r.width == 230)
    #expect(r.height == 38)
    #expect(r.minX == 205)      // 620 - 415
    #expect(r.maxY == 260)      // flush with the panel's top edge
}

@Test func peekIsWiderThanClosedAndStillTopAligned() {
    let r = NotchShape.visibleRect(presentation: .peek, anchor: anchor, panelFrame: panel)
    #expect(r.width == NotchGeometry.peekSize.width)
    #expect(r.height == NotchGeometry.peekSize.height)
    #expect(r.maxY == 260)
    #expect(r.midX == 320)      // centred on the anchor: 205 + 230/2
}

@Test func expandedFillsThePanel() {
    let r = NotchShape.visibleRect(presentation: .expanded, anchor: anchor, panelFrame: panel)
    #expect(r == CGRect(origin: .zero, size: panel.size))
}

@Test func clickBesideTheClosedNotchPassesThrough() {
    // A point in the menu bar, level with the notch but well to its left.
    let p = CGPoint(x: 20, y: 250)
    #expect(!NotchShape.contains(p, presentation: .closed, anchor: anchor, panelFrame: panel))
}

@Test func clickInsideTheClosedNotchIsCaptured() {
    let p = CGPoint(x: 320, y: 250)
    #expect(NotchShape.contains(p, presentation: .closed, anchor: anchor, panelFrame: panel))
}

@Test func clickBelowTheClosedNotchPassesThrough() {
    // Directly under the notch but below its 38pt height — desktop, not us.
    let p = CGPoint(x: 320, y: 100)
    #expect(!NotchShape.contains(p, presentation: .closed, anchor: anchor, panelFrame: panel))
}

@Test func sameClickIsCapturedWhenExpanded() {
    let p = CGPoint(x: 320, y: 100)
    #expect(NotchShape.contains(p, presentation: .expanded, anchor: anchor, panelFrame: panel))
}
