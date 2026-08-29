import AppKit
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// That the buttons are actually connected to the bridge, rather than
/// merely existing next to it.
@MainActor
struct MediaWiringTests {

    /// The same literal `AppDelegateStateFunnelTests` uses.
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
        delegate.shelfDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CreativeNotchMediaWiring-\(UUID().uuidString)")
        delegate.install(metrics: Self.notched)
        return delegate
    }

    /// Left unset, every media button would be dead on screen with nothing
    /// failing — the exact bug this test exists for.
    @Test func installingWiresTheMediaHandler() {
        #expect(makeDelegate().state.onMediaCommand != nil)
    }

    /// The row is hidden when the framework does not resolve. Buttons that
    /// look identical and do nothing are worse than no buttons.
    @Test func theControlsFollowAvailability() {
        #expect(makeDelegate().state.showsMediaControls == MediaRemoteBridge.isAvailable)
    }

    /// Sending must not depend on the panel being open, or on any tab
    /// being selected — the handler is set once at install.
    @Test func theHandlerSurvivesStateChanges() {
        let delegate = makeDelegate()
        delegate.state.transition(to: .open(.clipboard))
        delegate.state.transition(to: .closed)

        #expect(delegate.state.onMediaCommand != nil)
    }
}
