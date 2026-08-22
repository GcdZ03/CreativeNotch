import AppKit
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// `AppState` is the single funnel every derived value hangs off.
///
/// It carried one observer closure, which meant the first module to
/// register its own would silently replace `AppDelegate`'s -- taking the
/// hover tracking rect and outside-click dismissal with it, at runtime,
/// with no compiler help. (Follow-up F2.)
@MainActor
struct AppStateFunnelTests {

    private let anchor = Anchor.notch(CGRect(x: 620, y: 918, width: 230, height: 38))
    private let panel  = CGRect(x: 415, y: 696, width: 620, height: 260)

    // MARK: - F2: many observers, not one

    @Test func everyObserverHearsATransition() {
        let state = AppState()
        var heard: [String] = []
        state.observe { _ in heard.append("a") }
        state.observe { _ in heard.append("b") }
        state.observe { _ in heard.append("c") }

        state.transition(to: .open(.shelf))

        #expect(heard == ["a", "b", "c"])
    }

    @Test func observersFireInRegistrationOrder() {
        let state = AppState()
        var order: [Int] = []
        for i in 0..<5 { state.observe { _ in order.append(i) } }
        state.transition(to: .peek(.dragTarget))
        #expect(order == [0, 1, 2, 3, 4])
    }

    @Test func removingOneObserverLeavesTheOthers() {
        let state = AppState()
        var heard: [String] = []
        state.observe { _ in heard.append("keep") }
        let token = state.observe { _ in heard.append("drop") }
        state.observe { _ in heard.append("keep2") }

        state.removeObserver(token)
        state.transition(to: .open(.shelf))

        #expect(heard == ["keep", "keep2"])
    }

    @Test func removingAnUnknownTokenIsHarmless() {
        let other = AppState()
        let token = other.observe { _ in }

        let state = AppState()
        var fired = 0
        state.observe { _ in fired += 1 }
        state.removeObserver(token)
        state.transition(to: .open(.shelf))

        #expect(fired == 1)
    }

    @Test func anEqualTransitionNotifiesNobody() {
        let state = AppState()
        var fired = 0
        state.observe { _ in fired += 1 }
        state.transition(to: .closed)      // already closed
        #expect(fired == 0)
    }

    // MARK: - F4: geometry goes through the funnel too

    @Test func geometryChangesNotifyObservers() {
        let state = AppState()
        var changes: [AppState.Change] = []
        state.observe { changes.append($0) }

        state.setGeometry(anchor: anchor, panelFrame: panel)

        #expect(changes == [.geometry(anchor: anchor, panelFrame: panel)])
        #expect(state.anchor == anchor)
        #expect(state.panelFrame == panel)
    }

    @Test func unchangedGeometryNotifiesNobody() {
        let state = AppState()
        state.setGeometry(anchor: anchor, panelFrame: panel)
        var fired = 0
        state.observe { _ in fired += 1 }
        state.setGeometry(anchor: anchor, panelFrame: panel)
        #expect(fired == 0)
    }

    @Test func stateAndGeometryChangesAreDistinguishable() {
        let state = AppState()
        var changes: [AppState.Change] = []
        state.observe { changes.append($0) }

        state.transition(to: .open(.shelf))
        state.setGeometry(anchor: anchor, panelFrame: panel)

        #expect(changes == [
            .state(.open(.shelf)),
            .geometry(anchor: anchor, panelFrame: panel),
        ])
    }

    // MARK: - F5: one derivation of the drawn rect

    /// The view used to re-derive its size from a second `switch` over the
    /// presentation. Two derivations of one rectangle is the exact shape of
    /// this project's only Critical bug, so the view now asks
    /// `NotchShape` -- the tested one.
    @Test func theDrawnRectIsTheVisibleRect() {
        for state in [NotchState.closed, .peek(.dragTarget), .open(.shelf), .receiving] {
            let drawn = NotchRootView.drawnRect(state: state, anchor: anchor, panelFrame: panel)
            let visible = NotchShape.visibleRect(
                presentation: state.presentation, anchor: anchor, panelFrame: panel
            )
            #expect(drawn.size == visible.size)
            // Converted to the top-left origin SwiftUI lays out in.
            #expect(drawn.minX == visible.minX)
            #expect(drawn.minY == panel.height - visible.maxY)
        }
    }

    /// Where the two derivations actually diverge: an anchor whose centre
    /// is not the panel's centre. Simple centring would put the shape in
    /// the wrong place; `visibleRect` tracks the anchor.
    @Test func theDrawnRectTracksAnOffCentreAnchor() {
        let offset = Anchor.pill(CGRect(x: 415, y: 926, width: 180, height: 30))
        let drawn = NotchRootView.drawnRect(state: .closed, anchor: offset, panelFrame: panel)
        #expect(drawn.minX == 0)                      // anchor.minX - panel.minX
        #expect(drawn.width == 180)
        // Centring would have put it at (620 - 180) / 2 == 220.
        #expect(drawn.minX != 220)
    }
}
