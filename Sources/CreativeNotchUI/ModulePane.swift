import SwiftUI

/// A tab's content with the title row above it (spec §5.3).
///
/// The row is what the tab bar's text labels became when the tabs turned
/// into icons: the tab's name, an optional dimmed count, and its actions.
/// Content fills what is left.
struct ModulePane<Content: View>: View {
    let title: String
    var count: String? = nil
    /// The title row's verbs, left to right. Several are allowed so the
    /// shelf can offer "AirDrop All" beside "Clear"; most panes have one
    /// or none.
    var actions: [(label: String, perform: () -> Void)] = []
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.ink(0.92))
                if let count {
                    Text(count)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.ink(0.45))
                }
                Spacer(minLength: 8)
                ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                    Button(action.label, action: action.perform)
                        .buttonStyle(NotchButtonStyle(.quiet, compact: true))
                }
            }
            .frame(minHeight: 24)

            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
