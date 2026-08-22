import Testing
import CoreGraphics
@testable import CreativeNotchCore

// A notched MacBook: 1470x956pt, 38pt notch inset, 620pt of menu bar
// usable on each side of the notch.
private let notched = ScreenMetrics(
    frame: CGRect(x: 0, y: 0, width: 1470, height: 956),
    safeAreaTopInset: 38,
    auxiliaryTopLeftWidth: 620,
    auxiliaryTopRightWidth: 620,
    menuBarHeight: 38
)

// An external display: no safe area, no auxiliary areas.
private let external = ScreenMetrics(
    frame: CGRect(x: 1470, y: 0, width: 2560, height: 1440),
    safeAreaTopInset: 0,
    auxiliaryTopLeftWidth: 0,
    auxiliaryTopRightWidth: 0,
    menuBarHeight: 24
)

@Test func notchedScreenProducesNotchAnchor() {
    guard case .notch(let r) = NotchGeometry.anchor(for: notched) else {
        Issue.record("expected .notch"); return
    }
    #expect(r.width == 230)          // 1470 - (620 + 620)
    #expect(r.height == 38)
    #expect(r.minX == 620)
    #expect(r.maxY == 956)           // flush with the top of the screen
}

@Test func externalScreenProducesPillAnchor() {
    guard case .pill(let r) = NotchGeometry.anchor(for: external) else {
        Issue.record("expected .pill"); return
    }
    #expect(r.size == NotchGeometry.pillSize)
    #expect(r.midX == external.frame.midX)
    #expect(r.maxY == 1440 - 24 - NotchGeometry.pillTopGap)
}

@Test func zeroAuxiliaryWidthsFallBackToPill() {
    // A safe-area inset with no auxiliary areas is not a usable notch.
    let odd = ScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 1470, height: 956),
        safeAreaTopInset: 38,
        auxiliaryTopLeftWidth: 0,
        auxiliaryTopRightWidth: 0,
        menuBarHeight: 38
    )
    guard case .pill = NotchGeometry.anchor(for: odd) else {
        Issue.record("expected .pill"); return
    }
}

@Test func panelIsCenteredOnAnchorAndTopAligned() {
    let anchor = NotchGeometry.anchor(for: notched)
    let frame = NotchGeometry.panelFrame(for: anchor, in: notched)
    #expect(frame.width == NotchGeometry.expandedSize.width)
    #expect(frame.height == NotchGeometry.expandedSize.height)
    #expect(frame.midX == anchor.rect.midX)
    #expect(frame.maxY == anchor.rect.maxY)
}

@Test func panelIsClampedToScreenBounds() {
    // A pill hard against the left edge must not push the panel off-screen.
    let narrow = ScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 800, height: 600),
        safeAreaTopInset: 0,
        auxiliaryTopLeftWidth: 0,
        auxiliaryTopRightWidth: 0,
        menuBarHeight: 24
    )
    let anchor = Anchor.pill(CGRect(x: 0, y: 560, width: 180, height: 32))
    let frame = NotchGeometry.panelFrame(for: anchor, in: narrow)
    #expect(frame.minX >= narrow.frame.minX)
    #expect(frame.maxX <= narrow.frame.maxX)
}

@Test func panelIsClampedAtRightEdge() {
    // A pill hard against the right edge must not push the panel off-screen.
    let narrow = ScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 800, height: 600),
        safeAreaTopInset: 0,
        auxiliaryTopLeftWidth: 0,
        auxiliaryTopRightWidth: 0,
        menuBarHeight: 24
    )
    let anchor = Anchor.pill(CGRect(x: 620, y: 560, width: 180, height: 32))
    let frame = NotchGeometry.panelFrame(for: anchor, in: narrow)
    #expect(frame.maxX <= narrow.frame.maxX)
    #expect(frame.minX == 180)  // Clamped: 800 - 620 = 180
}
