import Foundation

/// A plain-English name for a picked colour, for VoiceOver (2026-10-24).
///
/// A swatch says nothing to someone who cannot see it, and "#3A7BD5" barely
/// more. "blue, #3A7BD5" says what was picked and what was copied. The names
/// are deliberately coarse -- eight hues, three greys, and "dark" or "light"
/// at the extremes -- because a precise name ("cornflower") would be a guess
/// presented as a fact.
public enum ColorName {
    public static func name(for color: SampledColor) -> String {
        let (hue, saturation, lightness) = color.hsl
        if lightness < 0.08 { return "black" }
        if lightness > 0.96 { return "white" }
        if saturation < 0.12 {
            if lightness < 0.2 { return "black" }
            if lightness > 0.85 { return "white" }
            return "grey"
        }
        let base = hueName(hue)
        if lightness < 0.25 { return "dark \(base)" }
        if lightness > 0.8 { return "light \(base)" }
        return base
    }

    /// The name, then the value as it was copied.
    public static func spoken(_ color: SampledColor, as format: ColorFormat) -> String {
        "\(name(for: color)), \(format.string(for: color))"
    }

    private static func hueName(_ hue: Double) -> String {
        switch hue {
        case ..<15:  return "red"
        case ..<45:  return "orange"
        case ..<70:  return "yellow"
        case ..<165: return "green"
        case ..<195: return "cyan"
        case ..<255: return "blue"
        case ..<290: return "purple"
        case ..<345: return "pink"
        default:     return "red"
        }
    }
}
