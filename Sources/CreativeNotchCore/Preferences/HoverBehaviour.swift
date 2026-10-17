import Foundation

/// What resting the pointer on the notch does (2026-10-17).
///
/// **Off by default.** Hovering peeks — what is playing, a finished timer,
/// a power change — and a click or a swipe opens the panel. The notch sits
/// on the path to the menu bar, and an accidental *peek* costs a glance
/// where an accidental *panel* covers the top of whatever you were doing.
///
/// On, resting for `openDelay` opens the panel instead of peeking, as
/// Boring Notch and MewNotch offer. The delay is longer than the peek's
/// 300ms dwell for the same reason.
public struct HoverBehaviour: Equatable, Sendable {
    public static let delayRange: ClosedRange<TimeInterval> = 0.2...1.0
    public static let defaultDelay: TimeInterval = 0.5
    /// The dwell before a peek, unchanged from before this setting existed.
    public static let peekDwell: Duration = .milliseconds(300)

    public var opensOnHover: Bool
    /// In seconds, clamped to `delayRange` and snapped to tenths — the
    /// slider's step — so a stored value never drifts.
    public var openDelay: TimeInterval {
        didSet { openDelay = Self.normalised(openDelay) }
    }

    public init(opensOnHover: Bool = false, openDelay: TimeInterval = HoverBehaviour.defaultDelay) {
        self.opensOnHover = opensOnHover
        self.openDelay = Self.normalised(openDelay)
    }

    /// How long the pointer has to rest before the notch acts.
    public var dwell: Duration {
        opensOnHover ? .milliseconds(Int((openDelay * 1000).rounded())) : Self.peekDwell
    }

    static func normalised(_ delay: TimeInterval) -> TimeInterval {
        guard delay.isFinite else { return defaultDelay }
        let clamped = min(max(delay, delayRange.lowerBound), delayRange.upperBound)
        return (clamped * 10).rounded() / 10
    }
}

/// Reads and writes `HoverBehaviour`, like `HotKeyStore` does the shortcut.
///
/// Caches nothing, for the reason `PreferencesStore` gives: a value read once
/// at construction is a setting that appears to work and changes nothing.
public final class HoverBehaviourStore {
    public enum Keys {
        public static let opensOnHover = "hover.opensPanel"
        public static let openDelay = "hover.openDelay"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// A value of the wrong type reads as unset and is not rewritten — the
    /// policy the module toggles and the shortcut follow.
    public func load() -> HoverBehaviour {
        let opens = PreferenceKeys.resolveEnabled(
            defaults.object(forKey: Keys.opensOnHover), shippedDefault: false
        )
        let delay = (defaults.object(forKey: Keys.openDelay) as? NSNumber)?.doubleValue
            ?? HoverBehaviour.defaultDelay
        return HoverBehaviour(opensOnHover: opens, openDelay: delay)
    }

    public func save(_ behaviour: HoverBehaviour) {
        defaults.set(behaviour.opensOnHover, forKey: Keys.opensOnHover)
        defaults.set(behaviour.openDelay, forKey: Keys.openDelay)
    }
}
