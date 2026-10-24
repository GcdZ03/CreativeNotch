import AppKit
import SwiftUI
import CreativeNotchCore

/// What the header's dropper needs: the history for its menu, the format for
/// its hint, and the two verbs. `nil` in `PanelHeader` while the module is
/// off, which is what takes the dropper away.
struct ColorPickerHeaderModel {
    let recent: [SampledColor]
    let format: ColorFormat
    let onPick: () -> Void
    let onCopy: (SampledColor) -> Void
}

/// The header's dropper, in the trailing ear beside the battery and the gear
/// (2026-10-24).
///
/// **In the header rather than a tab.** The leading ear is already full of
/// tabs on a 14" notch, and a picker is a verb, not a place: the gear beside
/// it is the precedent. Reachable from every tab, and gone with the switch.
///
/// A right-click lists the recent colours to copy again, so the history is
/// reachable without a fresh pick -- and VoiceOver offers the same menu as
/// the button's "Show menu" action.
struct ColorPickerButton: View {
    let model: ColorPickerHeaderModel

    var body: some View {
        Button(action: model.onPick) {
            Image(systemName: "eyedropper")
        }
        .buttonStyle(NotchIconButtonStyle())
        .help(String(localized: "Pick a colour from the screen", bundle: .creativeNotch))
        .accessibilityLabel(String(localized: "Pick a colour", bundle: .creativeNotch))
        .accessibilityHint(String(localized: "Then click anywhere on screen to copy that colour as \(ColorStripView.formatName(model.format)). Escape cancels.", bundle: .creativeNotch))
        .contextMenu {
            if !model.recent.isEmpty {
                Section(String(localized: "Copy Again", bundle: .creativeNotch)) {
                    ForEach(model.recent, id: \.self) { color in
                        Button {
                            model.onCopy(color)
                        } label: {
                            Label {
                                Text(model.format.string(for: color))
                            } icon: {
                                Image(nsImage: ColorSwatchImage.menu(for: color))
                            }
                        }
                        .accessibilityLabel(ColorName.spoken(color, as: model.format))
                    }
                }
            }
        }
    }
}

/// The result of a pick, over the bottom of the open panel's body
/// (2026-10-24): a large swatch, the value exactly as it was copied, and the
/// recent colours to copy again.
///
/// **On the body, not in a peek or a toast of its own.** The panel is where
/// the dropper was clicked and where it comes back after the loupe, so that
/// is where the person looks. It stays until the panel closes or its close
/// button is pressed -- nothing times it out, so nothing is scheduled -- and
/// it stacks over the pane like the welcome card does, opaque, so the pane's
/// controls are not reachable around it.
///
/// Arrangement only: what is copied, how it is worded and what VoiceOver
/// says are Core's (`ColorFormat`, `ColorName`), and the verbs are handed in.
struct ColorStripView: View {
    let picked: SampledColor
    let recent: [SampledColor]
    let format: ColorFormat
    let onCopy: (SampledColor) -> Void
    let onDismiss: () -> Void

    /// The format's short name, for the dropper's hint. Here with the strip
    /// rather than on the Core enum, the split `ColorFormatRow` makes.
    static func formatName(_ format: ColorFormat) -> String {
        switch format {
        case .hex:     return String(localized: "hex", bundle: .creativeNotch, comment: "Copy that colour as hex")
        case .rgb:     return String(localized: "RGB", bundle: .creativeNotch)
        case .hsl:     return String(localized: "HSL", bundle: .creativeNotch)
        case .swiftUI: return String(localized: "a SwiftUI colour", bundle: .creativeNotch, comment: "Copy that colour as a SwiftUI colour")
        }
    }

    var body: some View {
        // One row, and short: it sits in the band under every pane's last
        // control -- the timer's buttons end just above it -- so a taller
        // strip would cover something the person came to the pane for.
        HStack(spacing: 8) {
            ColorSwatch(color: picked, shape: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .notchFrame(width: 20, height: 20)
                .accessibilityHidden(true)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(format.string(for: picked))
                    .notchFont(13, weight: .semibold, design: .rounded)
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Copied", bundle: .creativeNotch)
                    .notchFont(11, weight: .medium, design: .rounded)
                    .foregroundStyle(.ink(0.55))
                    .fixedSize()
            }
            .layoutPriority(1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(localized: "Copied \(ColorName.spoken(picked, as: format))", bundle: .creativeNotch))

            Spacer(minLength: 6)

            // Only once there is something to go back to: a lone swatch would
            // repeat the one beside the value.
            if recent.count > 1 {
                HStack(spacing: 2) {
                    ForEach(recent, id: \.self) { color in
                        RecentSwatchButton(color: color, format: format, isCurrent: color == picked) {
                            onCopy(color)
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(String(localized: "Recent colours", bundle: .creativeNotch))
            }

            Button(action: onDismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(NotchIconButtonStyle())
            .help(String(localized: "Hide", bundle: .creativeNotch))
            .accessibilityLabel(String(localized: "Hide colour", bundle: .creativeNotch))
        }
        .padding(.leading, 6)
        .padding(.trailing, 0)
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black)
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.hairline(0.08))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.hairline(0.14), lineWidth: 1)
                }
        }
        .contentShape(.rect)
        // A click on the strip's blank space would otherwise reach the
        // shape's tap, which closes the open panel.
        .onTapGesture {}
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Picked colour", bundle: .creativeNotch))
    }
}

/// One recent colour: a click copies it again. The one just copied wears a
/// white ring, so the row says which value the strip is showing.
private struct RecentSwatchButton: View {
    let color: SampledColor
    let format: ColorFormat
    let isCurrent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ColorSwatch(color: color, shape: Circle())
                .notchFrame(width: 14, height: 14)
                .overlay {
                    if isCurrent {
                        Circle().strokeBorder(.ink(0.9), lineWidth: 1.5).padding(-3)
                    }
                }
                // A 24pt target around a 14pt dot.
                .notchFrame(width: 24, height: 24)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(format.string(for: color))
        .accessibilityLabel(ColorName.spoken(color, as: format))
        .accessibilityHint(String(localized: "Copies it again.", bundle: .creativeNotch))
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

/// A colour on black, with a hairline ring so a near-black pick does not
/// vanish into the panel. sRGB, the space the value was copied in.
struct ColorSwatch<S: InsettableShape>: View {
    let color: SampledColor
    let shape: S

    static func swiftUIColor(_ color: SampledColor) -> Color {
        Color(.sRGB, red: color.red, green: color.green, blue: color.blue)
    }

    var body: some View {
        shape
            .fill(Self.swiftUIColor(color))
            .overlay { shape.strokeBorder(.hairline(0.28), lineWidth: 1) }
    }
}

enum ColorSwatchImage {
    /// A swatch for a menu item. A real image, because a menu draws an
    /// `NSImage` and not a SwiftUI shape; not a template, so it keeps its
    /// colour.
    @MainActor
    static func menu(for color: SampledColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1).setFill()
            path.fill()
            NSColor.separatorColor.setStroke()
            path.lineWidth = 1
            path.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }
}
