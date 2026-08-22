import SwiftUI
import CreativeNotchCore

@Observable
public final class AppState {

    /// What the panel is showing.
    ///
    /// `private(set)` on purpose: the hover tracking rect, the hit-test
    /// region and the drawn shape are all *derived* from this value, so
    /// every change has to be followed by a re-sync. Assigning it
    /// directly left the tracking rect describing the previous
    /// presentation -- harmless for a hover-driven peek, fatal for a
    /// programmatic state like `.receiving`, where a stale rect turns a
    /// drag moving below the notch into a `mouseExited` that tears the
    /// drop target down mid-drag.
    ///
    /// `transition(to:)` is the single funnel. The compiler enforces it:
    /// nothing outside this type can assign `state`.
    public private(set) var state: NotchState = .closed

    public var anchor: CreativeNotchCore.Anchor = .pill(.zero)

    /// Runs after every accepted transition, with the new state.
    /// `AppDelegate` installs the tracking-rect re-sync here; anything
    /// else that must follow the state (the four planned features all
    /// will) hangs off the same hook rather than adding a fifth
    /// hand-synced call site.
    ///
    /// `@ObservationIgnored` because it is wiring, not observable state --
    /// re-installing it must never invalidate a SwiftUI view.
    @ObservationIgnored
    public var onTransition: ((NotchState) -> Void)?

    public init() {}

    /// The only way `state` ever changes.
    ///
    /// Equal transitions are dropped: `@Observable` does not dedupe, and
    /// a redundant assignment would force a redraw for no visible
    /// difference. The derived rects are functions of the state, so
    /// skipping the callback for an unchanged state cannot leave them
    /// stale.
    public func transition(to next: NotchState) {
        guard next != state else { return }
        state = next
        onTransition?(next)
    }
}

public struct NotchRootView: View {
    @Bindable var app: AppState

    public init(app: AppState) {
        self.app = app
    }

    public var body: some View {
        VStack(spacing: 0) {
            shape
                .frame(width: width, height: height)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: app.state)
    }

    private var shape: some View {
        RoundedRectangle(cornerRadius: app.anchor.isNotch && app.state == .closed ? 0 : 14)
            .fill(.black)
            .overlay {
                if app.state != .closed {
                    Text(label)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
            .onTapGesture {
                // Through the funnel, like every other mutation -- this
                // path used to assign `state` directly and so was the one
                // transition that never re-synced the tracking rect.
                switch app.state {
                case .open:  app.transition(to: .closed)
                default:     app.transition(to: .open(.shelf))
                }
            }
    }

    private var label: String {
        switch app.state {
        case .closed:          return ""
        case .peek:            return "CreativeNotch"
        case .open(let tab):   return tab.rawValue.capitalized
        case .receiving:       return "Drop here"
        }
    }

    private var width: CGFloat {
        switch app.state.presentation {
        case .closed:   return app.anchor.rect.width
        case .peek:     return NotchGeometry.peekSize.width
        case .expanded: return NotchGeometry.expandedSize.width
        }
    }

    private var height: CGFloat {
        switch app.state.presentation {
        case .closed:   return app.anchor.rect.height
        case .peek:     return NotchGeometry.peekSize.height
        case .expanded: return NotchGeometry.expandedSize.height
        }
    }
}
