import SwiftUI

/// The panel's one button: a capsule, white on black (spec §5.10).
///
/// Stock `.bordered` styles resolve their colours against the appearance,
/// and once rendered the timer's Pause button black-on-black
/// (`NotchPanel.swift`). Styling everything explicitly, as every other view
/// in the panel already does, is what keeps that from recurring.
///
/// Hover and pressed states change on input only. Nothing here pulses.
struct NotchButtonStyle: ButtonStyle {
    enum Emphasis { case quiet, prominent }

    var emphasis: Emphasis = .quiet

    init(_ emphasis: Emphasis = .quiet) { self.emphasis = emphasis }

    func makeBody(configuration: Configuration) -> some View {
        NotchButtonBody(configuration: configuration, emphasis: emphasis)
    }

    private struct NotchButtonBody: View {
        let configuration: Configuration
        let emphasis: Emphasis
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(emphasis == .prominent ? Color.black : Color.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Capsule().fill(fill))
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(Capsule())
                // An `NSTrackingArea` inside the panel, alive only while it is.
                .onHover { hovering = $0 }
        }

        private var fill: Color {
            switch emphasis {
            case .prominent:
                return .white.opacity(configuration.isPressed ? 0.8 : 1)
            case .quiet:
                let base = configuration.isPressed ? 0.22 : (hovering ? 0.16 : 0.10)
                return .white.opacity(base)
            }
        }
    }
}

/// The panel's one field (spec §5.10): dark, ringed, centred tabular digits.
struct NotchFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .monospacedDigit()
            .multilineTextAlignment(.center)
            .foregroundStyle(.white)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.white.opacity(0.08))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                    }
            }
    }
}

/// A 34×24 icon button for the header: the tabs and the gear.
struct NotchIconButtonStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white.opacity(selected ? 0.95 : 0.55))
            .frame(width: 34, height: 24)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.white.opacity(selected ? 0.14 : (configuration.isPressed ? 0.10 : 0)))
            }
            .contentShape(.rect)
    }
}
