import AppKit
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// Click pass-through through the *whole* assembled panel, not just the
/// hosting view.
///
/// `HitTestingHostingViewTests` exercises that one view in isolation, which
/// is not the same question: the panel's content view is what AppKit asks
/// first, and `NSView.hitTest` returns `self` for any in-bounds point when
/// no subview claims it.
@MainActor
struct PanelPassthroughTests {

    private static let notched = ScreenMetrics(
        frame: CGRect(x: 1470, y: 200, width: 1470, height: 956),
        safeAreaTopInset: 38,
        auxiliaryTopLeftWidth: 620,
        auxiliaryTopRightWidth: 620,
        menuBarHeight: 38
    )

    private func makeDelegate() -> AppDelegate {
        let delegate = AppDelegate()
        delegate.growthDelay = .zero
        delegate.install(metrics: Self.notched)
        return delegate
    }

    /// The closed notch occupies panel-local (195, 222, 230, 38). A point
    /// level with it but far to the left is menu bar, not us.
    @Test func aClickBesideTheNotchPassesThroughTheWholePanel() throws {
        let delegate = makeDelegate()
        let content = try #require(delegate.panel?.contentView)
        #expect(content.hitTest(NSPoint(x: 20, y: 240)) == nil)
    }

    @Test func aClickBelowTheNotchPassesThroughTheWholePanel() throws {
        let delegate = makeDelegate()
        let content = try #require(delegate.panel?.contentView)
        #expect(content.hitTest(NSPoint(x: 310, y: 100)) == nil)
    }

    @Test func aClickOnTheNotchIsCapturedByTheWholePanel() throws {
        let delegate = makeDelegate()
        let content = try #require(delegate.panel?.contentView)
        #expect(content.hitTest(NSPoint(x: 310, y: 240)) != nil)
    }

    @Test func whenOpenTheWholePanelCaptures() throws {
        let delegate = makeDelegate()
        delegate.state.transition(to: .open(.shelf))
        let content = try #require(delegate.panel?.contentView)
        #expect(content.hitTest(NSPoint(x: 310, y: 100)) != nil)
    }
}
