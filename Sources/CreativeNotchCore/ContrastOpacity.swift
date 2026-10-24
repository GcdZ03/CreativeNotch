/// How dim a white may be drawn, given whether Increase Contrast is on.
///
/// The panel is white on black, and its hierarchy is all opacity: a title
/// at 0.92, its count at 0.45, the clipboard's time at 0.4, hairlines at
/// 0.08-0.12. That reads well at standard contrast and is exactly what
/// Increase Contrast exists to undo, so every dimmed white in the panel is
/// passed through here rather than each view guessing a lifted value.
///
/// **Standard contrast is returned untouched.** The default look is the
/// design; this only ever moves a value when the user has asked for it.
///
/// Under the setting a value is lifted onto `floor ... 1` rather than
/// clamped up to the floor, so the order survives: a title still reads
/// above its count, a selected tab above an unselected one. Clamping would
/// have flattened every secondary label to one grey. Zero stays zero: it is
/// a switched-off state (an unhovered row's highlight), not a faint one.
public enum ContrastOpacity {

    /// What the white is drawing. Text needs far more lift than a hairline,
    /// whose whole job is to be quieter than the text beside it.
    public enum Role: Sendable, CaseIterable {
        /// Secondary and tertiary text and glyphs.
        case text
        /// Borders, dividers, and the faint fills behind controls.
        case hairline
    }

    /// No dimmed text reads fainter than this under Increase Contrast.
    public static let textFloor = 0.7

    /// No hairline reads fainter than this under Increase Contrast.
    public static let hairlineFloor = 0.25

    public static func opacity(_ nominal: Double, role: Role, increased: Bool) -> Double {
        let clamped = min(1, max(0, nominal))
        guard increased, clamped > 0 else { return clamped }
        let floor = role == .text ? textFloor : hairlineFloor
        return floor + (1 - floor) * clamped
    }
}
