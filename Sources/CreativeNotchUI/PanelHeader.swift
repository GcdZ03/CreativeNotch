import SwiftUI
import CreativeNotchCore

/// The open panel's top band: tabs in the leading ear, battery and the gear
/// in the trailing ear, and the camera housing black between them (spec §5.1).
///
/// Widths come from `PanelLayout`, the same function that gives the peeks
/// their `notchGap`; this view draws three columns and decides nothing. On a
/// pill Mac the gap is zero and the two ears are each half the width, so the
/// header reads as one row.
struct PanelHeader: View {
    let layout: PanelLayout
    let selected: CreativeNotchCore.Tab
    let enabled: Preferences
    let hasBattery: Bool
    let power: PowerSnapshot?
    let onSelect: (CreativeNotchCore.Tab) -> Void
    let onSettings: () -> Void
    /// The colour picker's dropper, or `nil` while the module is off.
    var colorPicker: ColorPickerHeaderModel? = nil

    var body: some View {
        HStack(spacing: 0) {
            PanelTabBar(selected: selected, enabled: enabled, hasBattery: hasBattery, onSelect: onSelect)
                .padding(.leading, 12)
                .frame(width: layout.leadingEarWidth, alignment: .leading)

            // The camera housing. Nothing is drawn here on purpose.
            Color.clear.frame(width: layout.notchGap)

            HStack(spacing: 10) {
                // First, nearest the housing: a verb like the gear, kept
                // apart from it by the battery so neither is hit for the
                // other.
                if let colorPicker {
                    ColorPickerButton(model: colorPicker)
                }
                if hasBattery, let power {
                    BatteryCell(level: power.level, isCharging: power.isCharging)
                }
                Button(action: onSettings) {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(NotchIconButtonStyle())
                .help("Settings")
                .accessibilityLabel("Settings")
            }
            .padding(.trailing, 12)
            .frame(width: layout.trailingEarWidth, alignment: .trailing)
        }
        .frame(height: layout.headerHeight)
    }
}

/// A small battery glyph with the level beside it. Static: it redraws when
/// the snapshot does, which is notification-driven.
///
/// The fill's colour is not the only signal: the glyph Core picks (a bolt
/// while charging, and under Differentiate Without Color a mark when low)
/// sits beside the level, where at 9pt it is legible. Inside a 22×11 cell
/// it would not be.
struct BatteryCell: View {
    let level: Int
    let isCharging: Bool
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    /// Static so which glyph shows for which state is testable without
    /// rendering. Core decides; this only supplies the tone.
    static func glyph(level: Int, isCharging: Bool, differentiateWithoutColor: Bool) -> String? {
        PowerGaugeTone.tone(level: level, isCharging: isCharging)
            .glyph(differentiateWithoutColor: differentiateWithoutColor)
    }

    var body: some View {
        HStack(spacing: 6) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(.ink(0.55), lineWidth: 1.5)
                    .frame(width: 22, height: 11)
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(tone)
                    .frame(width: max(2, 16 * CGFloat(min(100, max(0, level))) / 100), height: 5)
                    .padding(.leading, 3)
            }
            .overlay(alignment: .trailing) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(.ink(0.55))
                    .frame(width: 2, height: 4)
                    .offset(x: 3)
            }
            if let glyph = Self.glyph(
                level: level,
                isCharging: isCharging,
                differentiateWithoutColor: differentiateWithoutColor
            ) {
                Image(systemName: glyph)
                    .notchFont(9, weight: .bold)
                    .foregroundStyle(.ink(0.7))
            }
            Text("\(level)%")
                .notchFont(11, weight: .medium, design: .rounded)
                .monospacedDigit()
                .rollingDigits(level)
                .foregroundStyle(.ink(0.7))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery \(level) percent\(isCharging ? ", charging" : "")")
    }

    private var tone: Color {
        switch PowerGaugeTone.tone(level: level, isCharging: isCharging) {
        case .normal:   return .white
        case .low:      return .yellow
        case .charging: return .green
        }
    }
}
