import Foundation

/// How long the shelf keeps a file before it goes to the Trash (2026-10-24).
///
/// Stored as a number of days, with `0` for never. Days rather than seconds
/// so `defaults read` shows something a person can check at a glance, and an
/// enum rather than a free number because the Settings row is a menu: a
/// value that is not on it has nowhere to show.
public enum ShelfExpiry: Int, CaseIterable, Sendable {
    case oneDay = 1
    case sevenDays = 7
    case thirtyDays = 30
    case never = 0

    /// `nil` for never, which switches the purge off rather than setting a
    /// very large age — a "never" that expired in 2,000 years would be a
    /// number pretending to be a promise.
    public var maxAge: TimeInterval? {
        self == .never ? nil : TimeInterval(rawValue) * 24 * 3600
    }

    public var label: String {
        switch self {
        case .oneDay:     return "1 day"
        case .sevenDays:  return "7 days"
        case .thirtyDays: return "30 days"
        case .never:      return "Never"
        }
    }
}

/// What plays when a countdown finishes (2026-10-24).
///
/// The built-in alerts in `/System/Library/Sounds` and nothing else: no
/// bundled asset to ship or license, and a name `NSSound` cannot find plays
/// nothing at all, silently, which would read as a broken setting. The raw
/// value *is* the `NSSound` name, so there is no second table to keep in
/// step. "None" is offered because the peek is the primary signal and the
/// chime only amplifies it.
public enum ChimeSound: String, CaseIterable, Sendable {
    case none = "None"
    case basso = "Basso"
    case blow = "Blow"
    case bottle = "Bottle"
    case frog = "Frog"
    case funk = "Funk"
    case glass = "Glass"
    case hero = "Hero"
    case morse = "Morse"
    case ping = "Ping"
    case pop = "Pop"
    case purr = "Purr"
    case sosumi = "Sosumi"
    case submarine = "Submarine"
    case tink = "Tink"

    /// The name to hand `NSSound(named:)`, or `nil` for silence.
    public var soundName: String? { self == .none ? nil : rawValue }
}

/// The numbers that used to be hard-coded, now chosen in Settings
/// (2026-10-24): the shelf's capacity and expiry, the clipboard's history
/// size, the timer's three presets and its chime.
///
/// **Every default is the old constant**, so a domain with none of these
/// keys — a fresh install, or `dev.sh --fresh` — behaves exactly as the app
/// did before they existed.
///
/// A value, like `HoverBehaviour`, and it normalises itself on every write
/// the same way: a capacity that is not on the menu reads as the default, and
/// a preset is clamped to what `Countdown` will accept. So however a `Limits`
/// was built — from a hand-edited domain, or a field in Settings — the stores
/// are never handed a number they would have to second-guess.
public struct Limits: Equatable, Sendable {
    public static let shelfCapacityChoices = [10, 20, 50]
    public static let defaultShelfCapacity = 20
    public static let defaultShelfExpiry = ShelfExpiry.sevenDays

    public static let clipboardCapacityChoices = [25, 50, 100]
    public static let defaultClipboardCapacity = 50

    /// 5 / 10 / 25: a pomodoro, and the two kitchen-timer cases.
    public static let defaultTimerPresets = [5, 10, 25]

    /// What a preset may be: the stepper's range, which is itself derived
    /// from `Countdown.maxDuration`. A preset of 120 would be a button that
    /// `Countdown` refuses — Start silently doing nothing — so the bound is
    /// the countdown's rather than a rounder number.
    public static var presetRange: ClosedRange<Int> { TimerStepper.minimum...TimerStepper.maximum }

    public static let defaultChime = ChimeSound.glass

    public var shelfCapacity: Int {
        didSet { shelfCapacity = Self.choice(shelfCapacity, among: Self.shelfCapacityChoices, default: Self.defaultShelfCapacity) }
    }
    public var shelfExpiry: ShelfExpiry
    public var clipboardCapacity: Int {
        didSet { clipboardCapacity = Self.choice(clipboardCapacity, among: Self.clipboardCapacityChoices, default: Self.defaultClipboardCapacity) }
    }
    /// Always three, each within `presetRange`, in the order the user gave.
    public var timerPresets: [Int] {
        didSet { timerPresets = Self.normalisedPresets(timerPresets) }
    }
    public var chime: ChimeSound

    public init(
        shelfCapacity: Int = Limits.defaultShelfCapacity,
        shelfExpiry: ShelfExpiry = Limits.defaultShelfExpiry,
        clipboardCapacity: Int = Limits.defaultClipboardCapacity,
        timerPresets: [Int] = Limits.defaultTimerPresets,
        chime: ChimeSound = Limits.defaultChime
    ) {
        self.shelfCapacity = Self.choice(shelfCapacity, among: Self.shelfCapacityChoices, default: Self.defaultShelfCapacity)
        self.shelfExpiry = shelfExpiry
        self.clipboardCapacity = Self.choice(clipboardCapacity, among: Self.clipboardCapacityChoices, default: Self.defaultClipboardCapacity)
        self.timerPresets = Self.normalisedPresets(timerPresets)
        self.chime = chime
    }

    // MARK: - Normalising

    static func choice(_ value: Int, among choices: [Int], default fallback: Int) -> Int {
        choices.contains(value) ? value : fallback
    }

    /// The wrong count is not repaired element by element — there is no
    /// telling which of four values was meant to go — so it reads as the
    /// defaults. A value out of range is clamped, the way the hover delay is:
    /// the intent ("as long as it goes") is clear.
    static func normalisedPresets(_ presets: [Int]) -> [Int] {
        guard presets.count == defaultTimerPresets.count else { return defaultTimerPresets }
        return presets.map { min(max($0, presetRange.lowerBound), presetRange.upperBound) }
    }

    // MARK: - Resolving raw defaults values

    // Pure functions of `Any?`, like `PreferenceKeys.resolveEnabled`, and with
    // its policy: absent or wrongly typed reads as the default and is not
    // rewritten. A `String` is never parsed — "20" working while "twenty"
    // silently does not is a worse surprise than neither.

    /// A whole `NSNumber` that is one of `choices`, or `fallback`.
    public static func resolveChoice(_ raw: Any?, among choices: [Int], default fallback: Int) -> Int {
        guard let value = wholeNumber(raw), choices.contains(value) else { return fallback }
        return value
    }

    public static func resolveExpiry(_ raw: Any?) -> ShelfExpiry {
        wholeNumber(raw).flatMap(ShelfExpiry.init(rawValue:)) ?? defaultShelfExpiry
    }

    /// An array of three numbers, each clamped. Anything else — a string, an
    /// array of strings, the wrong count — is the defaults.
    public static func resolvePresets(_ raw: Any?) -> [Int] {
        guard let array = raw as? [Any] else { return defaultTimerPresets }
        let numbers = array.compactMap(wholeNumber)
        guard numbers.count == array.count else { return defaultTimerPresets }
        return normalisedPresets(numbers)
    }

    /// Matched exactly, case included: the raw value is an `NSSound` name, and
    /// a name that merely resembles one is not a sound.
    public static func resolveChime(_ raw: Any?) -> ChimeSound {
        (raw as? String).flatMap(ChimeSound.init(rawValue:)) ?? defaultChime
    }

    /// `NSNumber` holding an integer, and only that. A boolean bridges to
    /// `NSNumber` too, as 1 or 0 — which are expiry choices (one day, never),
    /// so `defaults write … -bool YES` would otherwise trash a week of shelf.
    /// It is a wrongly typed value and is rejected like a string.
    private static func wholeNumber(_ raw: Any?) -> Int? {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double == double.rounded(),
              abs(double) < Double(Int32.max)
        else { return nil }
        return Int(double)
    }
}
