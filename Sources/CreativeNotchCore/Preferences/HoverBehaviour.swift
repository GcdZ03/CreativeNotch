import Foundation

/// What resting the pointer on the notch does (2026-10-17).
///
/// **Off by default.** Hovering peeks — what is playing, a finished timer,
/// a power change — and a click or a swipe opens the panel. The notch sits
/// on the path to the menu bar, and an accidental *peek* costs a glance
/// where an accidental *panel* covers the top of whatever you were doing.
///
/// On, resting opens the panel, as Boring Notch and MewNotch offer — but
/// **peek first** (2026-10-18). The peek appears at the usual 300ms, and the
/// panel follows only if the pointer keeps resting for `openDelay` more. Going
/// straight to the panel skipped the music peek, the only place with the
/// progress bar and the sideways swipe to skip. With nothing to peek, the
/// panel opens at `openDelay` from arriving.
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

    /// How long the pointer rests before the notch acts at all: the peek's
    /// 300ms, or the chosen delay when that is shorter, so a 0.2s setting is
    /// not held back to 0.3s.
    public var dwell: Duration {
        guard opensOnHover else { return Self.peekDwell }
        return min(Self.peekDwell, Self.duration(openDelay))
    }

    /// How much longer, after the dwell, before the panel opens — `nil` when
    /// hover never opens it.
    ///
    /// After a peek, the whole `openDelay`, so the peek is on screen long
    /// enough to read or to swipe on. With nothing to peek, only what is left
    /// of `openDelay` once the dwell is counted.
    public func openWait(afterPeek: Bool) -> Duration? {
        guard opensOnHover else { return nil }
        if afterPeek { return Self.duration(openDelay) }
        let left = Self.duration(openDelay) - dwell
        return left > .zero ? left : .zero
    }

    private static func duration(_ seconds: TimeInterval) -> Duration {
        .milliseconds(Int((seconds * 1000).rounded()))
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
