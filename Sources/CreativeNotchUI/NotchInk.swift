import SwiftUI
import CreativeNotchCore

/// A dimmed white that honours Increase Contrast: the panel's one way of
/// drawing secondary text, glyphs and hairlines.
///
/// `.foregroundStyle(.ink(0.4))` in place of `.white.opacity(0.4)`. The
/// value is the design at standard contrast and is drawn exactly as before;
/// under Increase Contrast it is lifted by `ContrastOpacity`, which owns the
/// rule. Nothing is decided here.
///
/// A `ShapeStyle` rather than a modifier or an `@Environment` read in every
/// view, because `resolve(in:)` is handed the environment of wherever the
/// style is drawn — so one call site swap is the whole change, in a text
/// colour, a fill, or a stroke alike, and toggling the setting in System
/// Settings redraws the panel with no observer of ours.
struct NotchInk: ShapeStyle {
    let nominal: Double
    let role: ContrastOpacity.Role

    /// Static so the mapping is testable without an environment the test
    /// could not build: `colorSchemeContrast` has no public setter.
    static func color(
        _ nominal: Double,
        role: ContrastOpacity.Role,
        contrast: ColorSchemeContrast
    ) -> Color {
        .white.opacity(ContrastOpacity.opacity(nominal, role: role, increased: contrast == .increased))
    }

    func resolve(in environment: EnvironmentValues) -> Color {
        Self.color(nominal, role: role, contrast: environment.colorSchemeContrast)
    }
}

extension ShapeStyle where Self == NotchInk {
    /// Secondary or tertiary text, or a glyph, at `opacity` white.
    static func ink(_ opacity: Double) -> NotchInk {
        NotchInk(nominal: opacity, role: .text)
    }

    /// A border, divider or faint fill at `opacity` white.
    static func hairline(_ opacity: Double) -> NotchInk {
        NotchInk(nominal: opacity, role: .hairline)
    }
}
