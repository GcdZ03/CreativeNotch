import SwiftUI
import CreativeNotchCore

/// "Layout" in Settings (2026-10-24): the panel's width, its corners, which
/// ear holds the tabs, the header's battery and the closed notch's badges.
///
/// Holds no copy of its own, like `LimitsRows`: every control reads
/// `controller.layoutOptions` -- `AppState`'s, which is observable -- and
/// writes the whole value back through `setLayoutOptions`, so what the rows
/// show is always what applied.
///
/// Zero runtime cost, which is why these are settings and not a module:
/// nothing here starts, observes or schedules anything, so there is nothing
/// for a module switch to stop.
struct LayoutRows: View {
    let controller: PreferencesController

    /// One field of `LayoutOptions`, both directions. Static and built from a
    /// key path, like `LimitsRows.binding`, so a test can drive the exact
    /// binding a control is given without rendering it.
    static func binding<Value>(
        _ keyPath: WritableKeyPath<LayoutOptions, Value>,
        on controller: PreferencesController
    ) -> Binding<Value> {
        Binding(
            get: { controller.layoutOptions[keyPath: keyPath] },
            set: { value in
                var options = controller.layoutOptions
                options[keyPath: keyPath] = value
                controller.setLayoutOptions(options)
            }
        )
    }

    // What each choice is called in the menus. Here rather than on the Core
    // enums, which store the choice and know nothing of how it is worded.

    static func title(for width: PanelWidth) -> String {
        switch width {
        case .compact:  return "Compact"
        case .standard: return "Default"
        case .wide:     return "Wide"
        }
    }

    static func title(for corners: PanelCorners) -> String {
        switch corners {
        case .tight:    return "Tight"
        case .standard: return "Default"
        case .round:    return "Round"
        }
    }

    static func title(for side: EarSide) -> String {
        switch side {
        case .left:  return "Left"
        case .right: return "Right"
        }
    }

    var body: some View {
        Picker(selection: Self.binding(\.width, on: controller)) {
            ForEach(PanelWidth.allCases, id: \.self) { Text(Self.title(for: $0)).tag($0) }
        } label: {
            SettingsLabel(
                title: "Panel width", detail: "How wide the open panel is.",
                symbol: "arrow.left.and.right", tint: .teal
            )
        }

        Picker(selection: Self.binding(\.corners, on: controller)) {
            ForEach(PanelCorners.allCases, id: \.self) { Text(Self.title(for: $0)).tag($0) }
        } label: {
            SettingsLabel(
                title: "Corners", detail: "How round the open panel's corners are.",
                symbol: "square.bottomhalf.filled", tint: .mint
            )
        }

        Picker(selection: Self.binding(\.tabsSide, on: controller)) {
            ForEach(EarSide.allCases, id: \.self) { Text(Self.title(for: $0)).tag($0) }
        } label: {
            SettingsLabel(
                title: "Tabs", detail: "Which side of the camera the tabs sit on.",
                symbol: "rectangle.split.3x1", tint: .indigo
            )
        }
        .pickerStyle(.segmented)

        Toggle(isOn: Self.binding(\.showsBattery, on: controller)) {
            SettingsLabel(
                title: "Battery in the header", detail: "The level beside the settings gear.",
                symbol: "battery.75percent", tint: .green
            )
        }

        Toggle(isOn: Self.binding(\.showsNowPlayingBadge, on: controller)) {
            SettingsLabel(
                title: "Now-playing badge", detail: "Artwork and bars beside the closed notch.",
                symbol: "music.note", tint: .pink
            )
        }

        Toggle(isOn: Self.binding(\.showsTimerBadge, on: controller)) {
            SettingsLabel(
                title: "Timer badge", detail: "The countdown beside the closed notch.",
                symbol: "timer", tint: .orange
            )
        }

        Toggle(isOn: Self.binding(\.showsDownloadsBadge, on: controller)) {
            SettingsLabel(
                title: "Downloads badge", detail: "The progress ring beside the closed notch.",
                symbol: "arrow.down.circle", tint: .teal
            )
        }
    }
}

/// A Settings row's label: a title over a caption, beside a tinted symbol --
/// the shape every row in the window already has.
private struct SettingsLabel: View {
    let title: String
    let detail: String
    let symbol: String
    let tint: Color

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint)
                )
        }
    }
}
