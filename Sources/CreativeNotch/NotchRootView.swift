import SwiftUI
import CreativeNotchCore

@Observable
final class AppState {
    var state: NotchState = .closed
    var anchor: CreativeNotchCore.Anchor = .pill(.zero)
}

struct NotchRootView: View {
    @Bindable var app: AppState

    var body: some View {
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
