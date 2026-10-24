import Foundation

/// How a picked colour goes onto the pasteboard: "Copy as" in Settings
/// (2026-10-24).
///
/// **The raw values are the stored preference**, so they are a compatibility
/// surface in the sense `ModuleID`'s are: renaming one abandons the choice
/// behind it, and it reads back as the default with nothing failing.
///
/// What each is *called* in the menu lives with the menu (`ColorFormatRow`),
/// the split `TextSize` and `TextSizeRow` already make.
public enum ColorFormat: String, CaseIterable, Sendable {
    /// `#3A7BD5`: what design tools, CSS and most colour fields accept.
    case hex
    /// `rgb(58, 123, 213)`, CSS functional notation.
    case rgb
    /// `hsl(215, 65%, 53%)`, CSS functional notation.
    case hsl
    /// `Color(red: 0.227, green: 0.482, blue: 0.835)`, pasteable into Swift.
    case swiftUI = "swiftui"

    /// Hex: the one format every colour field in every app takes.
    public static let `default`: ColorFormat = .hex

    public func string(for color: SampledColor) -> String {
        switch self {
        case .hex:
            return String(format: "#%02X%02X%02X", color.red8, color.green8, color.blue8)
        case .rgb:
            return "rgb(\(color.red8), \(color.green8), \(color.blue8))"
        case .hsl:
            let hsl = color.hsl
            // Rounded as CSS tools print it; a hue that rounds up to 360 is
            // the same angle as 0 and is written that way.
            let hue = Int(hsl.hue.rounded()) % 360
            let saturation = Int((hsl.saturation * 100).rounded())
            let lightness = Int((hsl.lightness * 100).rounded())
            return "hsl(\(hue), \(saturation)%, \(lightness)%)"
        case .swiftUI:
            // Three decimals: finer than one 8-bit step, so the value pasted
            // into code draws the pixel that was picked.
            return String(
                format: "Color(red: %.3f, green: %.3f, blue: %.3f)",
                color.red, color.green, color.blue
            )
        }
    }
}
