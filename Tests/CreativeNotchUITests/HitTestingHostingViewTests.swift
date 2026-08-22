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
}
