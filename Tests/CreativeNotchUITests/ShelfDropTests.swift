import AppKit
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// The drop path, driven through the container's own callbacks rather than
/// a synthesised `NSDraggingInfo` — which cannot be constructed outside
/// AppKit's own drag machinery.
@MainActor
struct ShelfDropTests {

    private static let notched = ScreenMetrics(
        frame: CGRect(x: 1470, y: 200, width: 1470, height: 956),
        safeAreaTopInset: 38,
        auxiliaryTopLeftWidth: 620,
        auxiliaryTopRightWidth: 620,
        menuBarHeight: 38
    )

    private func makeDelegate() throws -> AppDelegate {
        let delegate = AppDelegate()
        delegate.growthDelay = .zero
        delegate.shelfDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shelf-\(UUID().uuidString)")
        delegate.install(metrics: Self.notched)
        return delegate
    }

    @Test func aDragEnteringOpensTheDropTarget() throws {
        let delegate = try makeDelegate()
        let container = try #require(delegate.panel?.contentView as? PassthroughContainer)

        container.onDragEntered()

        #expect(delegate.state.state == .receiving)
    }

    @Test func aDragLeavingClosesIt() throws {
        let delegate = try makeDelegate()
        let container = try #require(delegate.panel?.contentView as? PassthroughContainer)

        container.onDragEntered()
        container.onDragExited()

        #expect(delegate.state.state == .closed)
    }

    @Test func droppingStoresTheItemAndOpensTheShelf() throws {
        let delegate = try makeDelegate()
        let container = try #require(delegate.panel?.contentView as? PassthroughContainer)

        container.onDragEntered()
        let accepted = container.onDrop([.text("stashed")])

        #expect(accepted)
        #expect(delegate.state.state == .open(.shelf))
        #expect(delegate.shelf?.items.count == 1)
        #expect(delegate.shelf?.items.first?.displayName == "Dropped Text.txt")
    }

    @Test func droppingNothingIsRefusedAndClosesUp() throws {
        let delegate = try makeDelegate()
        let container = try #require(delegate.panel?.contentView as? PassthroughContainer)

        container.onDragEntered()
        let accepted = container.onDrop([])

        #expect(accepted == false)
        #expect(delegate.state.state == .closed)
        #expect(delegate.shelf?.items.isEmpty == true)
    }

    /// Spec section 9: a drop whose files cannot be written is refused,
    /// not half-completed. A read-only directory makes every write fail.
    @Test func aDropThatCannotBeStoredIsRefused() throws {
        let delegate = try makeDelegate()
        let container = try #require(delegate.panel?.contentView as? PassthroughContainer)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: delegate.shelfDirectory.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: delegate.shelfDirectory.path)
        }

        container.onDragEntered()
        let accepted = container.onDrop([.text("cannot be written")])

        #expect(accepted == false)
        #expect(delegate.state.state == .closed)
        #expect(delegate.shelf?.items.isEmpty == true)
    }

    /// A drag in flight must outlive the cursor leaving the notch, or the
    /// drop can never land. The foundation guards this; confirm the shelf
    /// does not undo it.
    @Test func aMouseExitDuringADropDoesNotTearDownTheTarget() throws {
        let delegate = try makeDelegate()
        let container = try #require(delegate.panel?.contentView as? PassthroughContainer)

        container.onDragEntered()
        delegate.hoverView?.onExit()

        #expect(delegate.state.state == .receiving)
    }

    /// AppKit does not call `draggingExited` after an accepted drop -- only
    /// the drop path's own `defer { arbiter.setDragActive(false) }` clears
    /// the arbiter's drag flag in that case. Without it, `.dragTarget` would
    /// silently outrank every HUD event forever after the first successful
    /// drop, exactly the failure the drag fix was meant to foreclose. Mirrors
    /// `AppDelegateStateFunnelTests.endingTheDragStopsItOutrankingTheHUD`,
    /// which pins the same invariant for `onDragExited`.
    @Test func droppingClearsTheDragFlagSoALaterHUDEventIsNotOutranked() throws {
        let delegate = try makeDelegate()
        let container = try #require(delegate.panel?.contentView as? PassthroughContainer)

        container.onDragEntered()
        let accepted = container.onDrop([.text("stashed")])
        #expect(accepted)

        // Force the state back to closed without going through
        // `onDragExited`, so the only thing that could have cleared
        // `dragActive` in the arbiter is the drop path's own defer.
        delegate.state.transition(to: .closed)
        delegate.showHUD(.volume(0.5))

        #expect(delegate.state.state == .peek(.hud(HUDEvent(kind: .volume(0.5)))))
    }
}
