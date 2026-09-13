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
}
