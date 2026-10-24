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
            .background { Self.ring }
    }

    private static var ring: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(.hairline(0.08))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.hairline(0.12), lineWidth: 1)
            }
    }

    /// The field's look around a plain value, for an offscreen render:
    /// `ImageRenderer` cannot host the AppKit view behind a `TextField`.
    static func staticText(_ value: String) -> some View {
        Text(value)
            .notchFont(13, weight: .medium, design: .rounded)
            .monospacedDigit()
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background { ring }
    }
}

extension EnvironmentValues {
    /// Draws the panel's fields as their value in the field's ring instead
    /// of a live `TextField`. Off everywhere in the app; on only in an
    /// offscreen render, where the AppKit field would be a placeholder.
    @Entry var notchDrawsFieldsAsText: Bool = false
}

/// The panel's search field: `NotchFieldStyle`'s ring and fill, left-aligned
/// text after a magnifier, and a clear button once something is typed.
///
/// It never asks for focus. The panel takes the keyboard only for an open
/// somebody asked for (`PanelFocus`), and a field that grabbed first
/// responder on appearing would turn a hover-open into exactly the
/// keystroke theft that rule exists to prevent. A click in it makes the
/// panel key the way any click in the panel does, and editing starts there.
struct NotchSearchField: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .notchFont(11, weight: .semibold)
                .foregroundStyle(.ink(0.45))
                .accessibilityHidden(true)

            TextField("", text: $text, prompt: Text(prompt).foregroundStyle(.ink(0.4)))
                .textFieldStyle(.plain)
                .notchFont(12, weight: .medium, design: .rounded)
                .foregroundStyle(.ink(0.9))
                .accessibilityLabel(prompt)

            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .notchFont(11, weight: .semibold)
                        .foregroundStyle(.ink(0.45))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
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

/// Two choices in one capsule, for a title row: the timer tab's
/// Timer | Stopwatch (2026-10-24).
///
/// Drawn in the panel's own ink rather than a stock `.segmented` picker,
/// for the reason `NotchButtonStyle` gives: stock controls resolve their
/// colours against the appearance and have rendered black on black here.
/// The selected segment is a raised hairline with bright ink; the others
/// are dim ink on the track. Increase Contrast lifts both through
/// `NotchInk`, and the selection is also a trait, so VoiceOver says which
/// is chosen rather than it resting on brightness alone.
struct NotchSegmentedControl<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    let selection: Value
    let onSelect: (Value) -> Void
    var accessibilityLabel: String = "Mode"

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let selected = option.value == selection
                Button { onSelect(option.value) } label: {
                    Text(option.title)
                        .notchFont(11, weight: .semibold, design: .rounded)
                        .foregroundStyle(.ink(selected ? 0.95 : 0.55))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(.hairline(selected ? 0.18 : 0)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(.hairline(0.08)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }
}
