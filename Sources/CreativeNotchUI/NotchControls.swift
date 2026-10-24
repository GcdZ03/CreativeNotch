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

    /// A smaller capsule for a title row, where a full-size button would
    /// outweigh the title beside it.
    var compact = false

    init(_ emphasis: Emphasis = .quiet, compact: Bool = false) {
        self.emphasis = emphasis
        self.compact = compact
    }

    func makeBody(configuration: Configuration) -> some View {
        NotchButtonBody(configuration: configuration, emphasis: emphasis, compact: compact)
    }

    private struct NotchButtonBody: View {
        let configuration: Configuration
        let emphasis: Emphasis
        let compact: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .notchFont(compact ? 11 : 12, weight: .semibold, design: .rounded)
                .foregroundStyle(emphasis == .prominent ? Color.black : Color.white)
                .padding(.horizontal, compact ? 10 : 14)
                .padding(.vertical, compact ? 5 : 7)
                .background(Capsule().fill(fill))
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(Capsule())
                // An `NSTrackingArea` inside the panel, alive only while it is.
                .onHover { hovering = $0 }
        }

        /// A quiet capsule is a hairline fill, so Increase Contrast lifts it
        /// off the black; a prominent one is solid white already and is
        /// left alone.
        private var fill: AnyShapeStyle {
            switch emphasis {
            case .prominent:
                return AnyShapeStyle(.white.opacity(configuration.isPressed ? 0.8 : 1))
            case .quiet:
                let base = configuration.isPressed ? 0.22 : (hovering ? 0.16 : 0.10)
                return AnyShapeStyle(.hairline(base))
            }
        }
    }
}

/// The panel's one field (spec §5.10): dark, ringed, centred tabular digits.
struct NotchFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .notchFont(13, weight: .medium, design: .rounded)
            .monospacedDigit()
            .multilineTextAlignment(.center)
            .foregroundStyle(.white)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.hairline(0.08))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(.hairline(0.12), lineWidth: 1)
                    }
            }
    }
}

/// A 34×24 icon button for the header: the tabs and the gear.
struct NotchIconButtonStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .notchFont(13, weight: .medium)
            .foregroundStyle(.ink(selected ? 0.95 : 0.55))
            .notchFrame(width: 34, height: 24)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.hairline(selected ? 0.14 : (configuration.isPressed ? 0.10 : 0)))
            }
            .contentShape(.rect)
    }
}
