import Testing
import CoreGraphics
@testable import CreativeNotchCore

private let anchor = Anchor.notch(
    CGRect(x: 620, y: 918, width: 230, height: 38)
)
private let panel = CGRect(x: 415, y: 696, width: 620, height: 260)

// Local closed rect for `anchor`: (205, 222, 230, 38) — minX 205, maxX 435,
// minY 222, maxY 260. Peek widens by one ear (110) either side and keeps
// the notch's own height, so content lands beside the camera housing
// rather than behind it: (95, 222, 450, 38) — minX 95, maxX 545.

private let pillAnchor = Anchor.pill(
    CGRect(x: 500, y: 900, width: 180, height: 32)
)
// Local closed rect for `pillAnchor`: (85, 204, 180, 32) — minX 85, maxX 265,
// minY 204, maxY 236.

@Test func closedVisibleRectMatchesTheAnchorExactly() {
    let r = NotchShape.visibleRect(presentation: .closed, anchor: anchor, panelFrame: panel)
    #expect(r.width == 230)
    #expect(r.height == 38)
    #expect(r.minX == 205)      // 620 - 415
    #expect(r.maxY == 260)      // flush with the panel's top edge
}

@Test func peekIsWiderThanClosedAndStillTopAligned() {
    let r = NotchShape.visibleRect(presentation: .peek, anchor: anchor, panelFrame: panel)
    #expect(r.width == 230 + NotchGeometry.peekEarWidth * 2)
    #expect(r.height == 38)     // the notch's own height, not a taller slab
    #expect(r.maxY == 260)
    #expect(r.midX == 320)      // still centred on the anchor: 205 + 230/2
}

@Test func expandedFillsThePanel() {
    let r = NotchShape.visibleRect(presentation: .expanded, anchor: anchor, panelFrame: panel)
    #expect(r == CGRect(origin: .zero, size: panel.size))
}

@Test func clickBesideTheClosedNotchPassesThrough() {
    // A point in the menu bar, level with the notch but well to its left.
    let p = CGPoint(x: 20, y: 250)
    #expect(!NotchShape.visibleRect(presentation: .closed, anchor: anchor, panelFrame: panel).contains(p))
}

@Test func clickInsideTheClosedNotchIsCaptured() {
    let p = CGPoint(x: 320, y: 250)
    #expect(NotchShape.visibleRect(presentation: .closed, anchor: anchor, panelFrame: panel).contains(p))
}

@Test func clickBelowTheClosedNotchPassesThrough() {
    // Directly under the notch but below its 38pt height — desktop, not us.
    let p = CGPoint(x: 320, y: 100)
    #expect(!NotchShape.visibleRect(presentation: .closed, anchor: anchor, panelFrame: panel).contains(p))
}

@Test func sameClickIsCapturedWhenExpanded() {
    let p = CGPoint(x: 320, y: 100)
    #expect(NotchShape.visibleRect(presentation: .expanded, anchor: anchor, panelFrame: panel).contains(p))
}

// MARK: - Gap 1: .peek contains()

@Test func peekClickInsideTheWidenedBandIsCaptured() {
    // x=180 sits inside peek's widened band (minX 95, maxX 545) but
    // outside the narrower closed notch rect (minX 205, maxX 435) — this
    // specifically catches a mutation where .peek falls through to the
    // .closed rect.
    let p = CGPoint(x: 180, y: 230)
    #expect(NotchShape.visibleRect(presentation: .peek, anchor: anchor, panelFrame: panel).contains(p))
}

@Test func peekClickOutsideTheWidenedBandPassesThrough() {
    // Just past peek's right edge (maxX 545).
    let p = CGPoint(x: 560, y: 230)
    #expect(!NotchShape.visibleRect(presentation: .peek, anchor: anchor, panelFrame: panel).contains(p))
}

// MARK: - Gap 2: .pill anchor

@Test func pillClosedVisibleRectMatchesThePillAnchor() {
    let r = NotchShape.visibleRect(presentation: .closed, anchor: pillAnchor, panelFrame: panel)
    #expect(r == CGRect(x: 85, y: 204, width: 180, height: 32))
}

@Test func pillClickInsideIsCaptured() {
    let p = CGPoint(x: 150, y: 220) // inside (85-265, 204-236)
    #expect(NotchShape.visibleRect(presentation: .closed, anchor: pillAnchor, panelFrame: panel).contains(p))
}

@Test func pillClickOutsideIsNotCaptured() {
    let p = CGPoint(x: 20, y: 220) // well to the left of the pill
    #expect(!NotchShape.visibleRect(presentation: .closed, anchor: pillAnchor, panelFrame: panel).contains(p))
}

// MARK: - Gap 3: passthrough symmetry and boundary semantics

@Test func clickBesideTheClosedNotchOnTheRightPassesThrough() {
    // Symmetric to clickBesideTheClosedNotchPassesThrough: to the right of
    // the notch (maxX 435), still comfortably inside the panel (width 620),
    // level with the notch.
    let p = CGPoint(x: 600, y: 250)
    #expect(!NotchShape.visibleRect(presentation: .closed, anchor: anchor, panelFrame: panel).contains(p))
}

@Test func closedRectBoundaryIsInclusiveOfMinAndExclusiveOfMax() {
    // Pins down CGRect.contains' boundary convention explicitly: the near
    // (min) corner is inside the rect, the far (max) corner is outside.
    let minCorner = CGPoint(x: 205, y: 222)
    let maxCorner = CGPoint(x: 435, y: 260)
    #expect(NotchShape.visibleRect(presentation: .closed, anchor: anchor, panelFrame: panel).contains(minCorner))
    #expect(!NotchShape.visibleRect(presentation: .closed, anchor: anchor, panelFrame: panel).contains(maxCorner))
}
