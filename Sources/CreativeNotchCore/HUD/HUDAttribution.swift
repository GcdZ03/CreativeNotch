import Foundation

/// Decides whether a level change was caused by the volume or brightness
/// keys.
///
/// The notch stays silent for keypresses because Apple's own HUD already
/// covers them; it speaks for every other source, where macOS gives no
/// feedback at all. Nothing exposes whether Apple's HUD is on screen, so
/// the keypress is detected instead and correlated with the change it
/// caused.
///
/// Pure and time-injected, so the whole decision is testable without a
/// keyboard.
public enum HUDAttribution {

    /// How long after a keypress a level change is still attributed to it.
    public static let window: TimeInterval = 0.25

    /// - Parameters:
    ///   - changeAt: when the level actually changed.
    ///   - lastKeyAt: when a media key was last seen, or nil if never.
    public static func isKeyDriven(changeAt: TimeInterval, lastKeyAt: TimeInterval?) -> Bool {
        guard let lastKeyAt else { return false }
        let delta = changeAt - lastKeyAt
        // Negative means the key is stamped *after* the change it would
        // have caused — clocks from different sources are not guaranteed
        // to agree, and that ordering is nonsense rather than a match.
        return delta >= 0 && delta <= window
    }
}
