/// The one colour decision on the battery tab (spec §5.8).
///
/// White is the default, as everywhere in this notch. Yellow is the colour
/// the power module already uses for a low battery; green while charging is
/// what the menu bar item does, and it is the only time the gauge is telling
/// good news.
public enum PowerGaugeTone: Equatable, Sendable {
    case normal, low, charging

    /// The higher of the two thresholds macOS itself warns at, taken from
    /// `LowBatteryArming` rather than restated, so the gauge and the peek
    /// cannot disagree about what "low" is.
    public static let lowThreshold: Int = LowBatteryArming.thresholds.max() ?? 20

    public static func tone(level: Int, isCharging: Bool) -> PowerGaugeTone {
        if isCharging { return .charging }
        if level <= lowThreshold { return .low }
        return .normal
    }

    /// The SF Symbol drawn on the gauge, so the tone is not carried by
    /// colour alone.
    ///
    /// The charging bolt is shown always: it is what the menu bar's own
    /// battery does, so it reads as the system's convention rather than an
    /// accessibility mode. The low mark is shown only under Differentiate
    /// Without Color — for everyone else the yellow already says it, and a
    /// glyph over a nearly empty cell is noise. `.normal` is the absence of
    /// news and carries nothing.
    public func glyph(differentiateWithoutColor: Bool) -> String? {
        switch self {
        case .charging: return "bolt.fill"
        case .low:      return differentiateWithoutColor ? "exclamationmark" : nil
        case .normal:   return nil
        }
    }

    /// What VoiceOver says for a battery gauge: the level, then the tone
    /// when there is one -- "Battery 15 percent, low".
    ///
    /// The tone's other cues, the fill colour and the glyph, are visual; a
    /// label of the level alone left "low" unsaid to anyone not looking.
    /// Decided here, beside `tone`, so the spoken word and the colour cannot
    /// disagree about what low is.
    public static func spokenLabel(level: Int, isCharging: Bool) -> String {
        // Whole sentences, not a base plus a suffix, so a translator can
        // place the tone word where the language wants it.
        switch tone(level: level, isCharging: isCharging) {
        case .charging: return String(localized: "Battery \(level) percent, charging", bundle: .creativeNotch)
        case .low:      return String(localized: "Battery \(level) percent, low", bundle: .creativeNotch)
        case .normal:   return String(localized: "Battery \(level) percent", bundle: .creativeNotch)
        }
    }
}
