import AppKit
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// Does registering for dragged types give the container a drop region
/// wider than its hit-test region?
///
/// `PassthroughContainer.hitTest` returns nil outside the visible shape so
/// menu bar clicks pass through. If AppKit finds dragging destinations the
/// same way, the drop zone collapses to the notch and still looks correct.
@MainActor
struct DropRegionTests {

    private static let notched = ScreenMetrics(
        frame: CGRect(x: 1470, y: 200, width: 1470, height: 956),
        safeAreaTopInset: 38,
        auxiliaryTopLeftWidth: 620,
        auxiliaryTopRightWidth: 620,
        menuBarHeight: 38
    )

    @Test func theContainerIsRegisteredForFileDrops() throws {
        let delegate = AppDelegate()
        delegate.growthDelay = .zero
        delegate.install(metrics: Self.notched)
        let content = try #require(delegate.panel?.contentView)

        #expect(content.registeredDraggedTypes.contains(.fileURL))
    }

    /// The point that matters: deep in the panel, far outside the closed
    /// notch. Clicks there must pass through; drops there must not.
    @Test func aPointOutsideTheNotchIsStillInsideTheContainerBounds() throws {
        let delegate = AppDelegate()
        delegate.growthDelay = .zero
        delegate.install(metrics: Self.notched)
        let content = try #require(delegate.panel?.contentView)

        let deepInPanel = NSPoint(x: 310, y: 100)
        #expect(content.bounds.contains(deepInPanel))
        #expect(content.hitTest(deepInPanel) == nil)   // clicks pass through
    }
}
