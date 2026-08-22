import AppKit
import SwiftUI
import Testing
import CreativeNotchUI

/// Covers the one seam where two coordinate conventions meet: `hitTest`
/// must compare its point against `visibleRectProvider()`'s bottom-left,
/// y-up panel space — not `NSHostingView`'s own flipped (top-left, y-down)
/// space. Uses the reviewer's real 13" MacBook Air numbers: anchor
/// `(655, 919, 160, 37)` inside panel `(425, 696, 620, 260)`, which in
/// panel-local bottom-left coordinates is the band
/// `(230, 223, 160, 37)` — top-aligned, 223...260 vertically.
///
/// The inverted bug mirrors y around the panel height
/// (`buggy_y = height - true_y`), which produces two distinct failure
/// zones, both covered here:
///   1. true y inside the visible band (223...260) gets incorrectly
///      *nulled* — `clickInsideTheNotchBandIsCaptured`.
///   2. true y in the mirror-image zone near the panel's bottom
///      (0..<37) gets incorrectly *captured* — `clickNearThePanelBottomPassesThrough`.
///      This is the half of the bug a user would actually notice: a
///      ~160x37pt band near the bottom of the (mostly invisible) panel
///      silently swallowing clicks that should reach whatever is
///      underneath.
@MainActor
struct HitTestingHostingViewTests {

    private static let visibleRect = CGRect(x: 230, y: 223, width: 160, height: 37)

    private func makeHost() -> HitTestingHostingView<AnyView> {
        let panel = NotchPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 260))
        let host = HitTestingHostingView(rootView: AnyView(EmptyView()))
        host.visibleRectProvider = { Self.visibleRect }
        panel.contentView = host
        return host
    }

    @Test func clickInsideTheNotchBandIsCaptured() {
        let host = makeHost()
        #expect(host.hitTest(NSPoint(x: 300, y: 240)) != nil)
    }

    @Test func clickBelowTheNotchBandPassesThrough() {
        let host = makeHost()
        #expect(host.hitTest(NSPoint(x: 300, y: 100)) == nil)
    }

    /// The mirror-image failure zone: true panel-local y is 10, which is
    /// nowhere near the visible band (223...260), so this click must pass
    /// through. Under the inverted bug, `height - 10 = 250` *is* inside
    /// the band, so this point was incorrectly captured.
    @Test func clickNearThePanelBottomPassesThrough() {
        let host = makeHost()
        #expect(host.hitTest(NSPoint(x: 300, y: 10)) == nil)
    }
}
