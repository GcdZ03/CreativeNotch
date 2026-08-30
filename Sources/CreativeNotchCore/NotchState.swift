import Foundation

public enum Tab: String, CaseIterable, Equatable, Sendable {
    case shelf, clipboard, hud, power, timer
}

public struct TrackSnapshot: Equatable, Sendable {
    public var title: String
    public var artist: String
    public var isPlaying: Bool

    public init(title: String, artist: String, isPlaying: Bool) {
        self.title = title
        self.artist = artist
        self.isPlaying = isPlaying
    }
}

public enum HUDKind: Equatable, Sendable {
    case volume(Double)
    case brightness(Double)
    case mute(Bool)
}

public struct HUDEvent: Equatable, Sendable {
    public var kind: HUDKind

    public init(kind: HUDKind) { self.kind = kind }
}

/// What the completion peek shows: the duration that was set and how late
/// the timer fired.
///
/// Lateness is real, not a defensive placeholder: `Countdown.remaining` is
/// deliberately unclamped so a machine that sleeps through the deadline and
/// fires on wake can report exactly how late it was.
public struct TimerCompletion: Equatable, Sendable {
    public let duration: TimeInterval
    public let lateness: TimeInterval

    public init(duration: TimeInterval, lateness: TimeInterval) {
        self.duration = duration
        self.lateness = lateness
    }
}

/// A power change worth interrupting for.
///
/// Five cases, and Low Power Mode is the one that looks like padding but
/// is not. macOS turns it on automatically at 20%, and that automatic
/// case is exactly a state change worth announcing: the machine has
/// altered its own behaviour without being asked, and the person
/// wondering why their fans went quiet is who this peek is for.
///
/// "Fully charged" and the optimised-charging 80% hold are deliberately
/// absent. Neither is urgent, and the 80% hold is indistinguishable from
/// a fault without more IOKit archaeology than it is worth.
public enum PowerEvent: Equatable, Sendable {
    case pluggedIn(level: Int)
    case unplugged(level: Int)
    case lowBattery(threshold: Int, level: Int)
    case lowPowerMode(enabled: Bool)
}

/// What occupies the single peek slot.
public enum PeekContent: Equatable, Sendable {
    case hud(HUDEvent)
    case dragTarget
    case nowPlaying(TrackSnapshot)
    case timerDone(TimerCompletion)
    case power(PowerEvent)
}

/// The one state the panel is ever in.
public enum NotchState: Equatable, Sendable {
    case closed
    case peek(PeekContent)
    case open(Tab)
    case receiving

    public var presentation: NotchShape.Presentation {
        switch self {
        case .closed:            return .closed
        case .peek:              return .peek
        case .open, .receiving:  return .expanded
        }
    }
}
