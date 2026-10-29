import Foundation

public enum Tab: String, CaseIterable, Equatable, Sendable {
    case shelf, clipboard, power, timer, camera, calendar
}

public struct TrackSnapshot: Equatable, Sendable {
    public var title: String
    public var artist: String
    public var isPlaying: Bool
    /// Where playback is, when the player publishes it. Part of equality on
    /// purpose: a seek is a change worth republishing, and MediaRemote only
    /// sends one on play, pause and seek, never on a clock.
    public var position: PlaybackPosition?

    public init(title: String, artist: String, isPlaying: Bool, position: PlaybackPosition? = nil) {
        self.title = title
        self.artist = artist
        self.isPlaying = isPlaying
        self.position = position
    }
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
    case dragTarget
    case nowPlaying(TrackSnapshot)
    case timerDone(TimerCompletion)
    case power(PowerEvent)
    /// Downloads in progress: ambient, shown on hover over their badge.
    case downloads(DownloadSummary)
    /// A download that has just finished: transient, shown unasked.
    case downloadDone(DownloadCompletion)
    /// An audio Bluetooth device arriving or leaving (2026-10-24).
    case bluetooth(BluetoothAudioEvent)
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
        case .peek(.nowPlaying): return .mediaPeek
        case .peek(.power):      return .statusPeek
        // The battery's row, reused: an icon, the words, a bar and a number
        // is exactly what a download needs too, and a name is too long for
        // the one-line ears.
        case .peek(.downloads), .peek(.downloadDone): return .statusPeek
        // The battery peek's one row below the notch: an icon, a name and
        // a word, which is the same shape of message.
        case .peek(.bluetooth):  return .statusPeek
        case .peek:              return .peek
        case .open, .receiving:  return .expanded
        }
    }
}
