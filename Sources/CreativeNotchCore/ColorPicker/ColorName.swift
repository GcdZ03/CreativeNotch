import Foundation

/// A plain-language name for a picked colour, for VoiceOver (2026-10-24).
///
/// A swatch says nothing to someone who cannot see it, and "#3A7BD5" barely
/// more. "blue, #3A7BD5" says what was picked and what was copied. The names
/// are deliberately coarse -- eight hues, three greys, and "dark" or "light"
/// at the extremes -- because a precise name ("cornflower") would be a guess
/// presented as a fact.
public enum ColorName {
    public static func name(for color: SampledColor) -> String {
        let (hue, saturation, lightness) = color.hsl
        let black = String(localized: "black", bundle: .creativeNotch, comment: "A colour name, spoken")
        let white = String(localized: "white", bundle: .creativeNotch, comment: "A colour name, spoken")
        if lightness < 0.08 { return black }
        if lightness > 0.96 { return white }
        if saturation < 0.12 {
            if lightness < 0.2 { return black }
            if lightness > 0.85 { return white }
            return String(localized: "grey", bundle: .creativeNotch, comment: "A colour name, spoken")
        }
        let base = hueName(hue)
        if lightness < 0.25 { return String(localized: "dark \(base)", bundle: .creativeNotch, comment: "A dark shade of a colour: dark blue") }
        if lightness > 0.8 { return String(localized: "light \(base)", bundle: .creativeNotch, comment: "A light shade of a colour: light blue") }
        return base
    }

    /// The name, then the value as it was copied.
    public static func spoken(_ color: SampledColor, as format: ColorFormat) -> String {
        String(localized: "\(name(for: color)), \(format.string(for: color))", bundle: .creativeNotch,
               comment: "A colour's name, then its value as copied: blue, #3A7BD5")
    }

    private static func hueName(_ hue: Double) -> String {
        let red = String(localized: "red", bundle: .creativeNotch, comment: "A colour name, spoken")
        switch hue {
        case ..<15:  return red
        case ..<45:  return String(localized: "orange", bundle: .creativeNotch, comment: "A colour name, spoken")
        case ..<70:  return String(localized: "yellow", bundle: .creativeNotch, comment: "A colour name, spoken")
        case ..<165: return String(localized: "green", bundle: .creativeNotch, comment: "A colour name, spoken")
        case ..<195: return String(localized: "cyan", bundle: .creativeNotch, comment: "A colour name, spoken")
        case ..<255: return String(localized: "blue", bundle: .creativeNotch, comment: "A colour name, spoken")
        case ..<290: return String(localized: "purple", bundle: .creativeNotch, comment: "A colour name, spoken")
        case ..<345: return String(localized: "pink", bundle: .creativeNotch, comment: "A colour name, spoken")
        default:     return red
        }
    }
}
