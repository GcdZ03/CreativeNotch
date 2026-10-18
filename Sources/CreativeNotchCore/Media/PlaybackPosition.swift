import CoreGraphics
import Foundation

/// Where playback is in the current track.
///
/// MediaRemote does **not** tick the elapsed time. It republishes `elapsed`
/// with a timestamp of when that reading was true, on each play, pause and
/// seek. Measured on 2026-10-15 against Spotify: elapsed + (now − timestamp)
/// matched Spotify's own `player position` to within the gap between the
/// two reads, and the duration matched exactly.
///
/// So this stores the reading and its anchor, and every question takes
/// `now` — as `Countdown.remaining(at:)` does — rather than reading a
/// clock. Whether time is passing comes from `isPlaying`, which the bridge
/// queries; the dictionary's playback rate is not used, for the reason
/// `MediaPayload.snapshot` gives.
public struct PlaybackPosition: Equatable, Sendable {
    public let elapsed: TimeInterval
    public let duration: TimeInterval
    public let anchoredAt: Date

    /// `nil` when there is nothing to draw a bar against: no positive,
    /// finite duration (a live stream, or a player that publishes none),
    /// or a non-finite elapsed.
    public init?(elapsed: TimeInterval, duration: TimeInterval, anchoredAt: Date) {
        guard elapsed.isFinite, duration.isFinite, duration > 0 else { return nil }
        self.elapsed = elapsed
        self.duration = duration
        self.anchoredAt = anchoredAt
    }

    /// Clamped to the track: a reading anchored by another process's clock
    /// can be a little ahead of this one, and a track that ended without a
    /// fresh reading must not run past its own length.
    public func elapsed(at now: Date, isPlaying: Bool) -> TimeInterval {
        let advanced = isPlaying ? elapsed + now.timeIntervalSince(anchoredAt) : elapsed
        return min(max(advanced, 0), duration)
    }

    public func remaining(at now: Date, isPlaying: Bool) -> TimeInterval {
        duration - elapsed(at: now, isPlaying: isPlaying)
    }

    public func fraction(at now: Date, isPlaying: Bool) -> Double {
        elapsed(at: now, isPlaying: isPlaying) / duration
    }

    // MARK: - Seeking (2026-10-18)

    /// The time a point on a progress bar stands for: `x` along a bar
    /// `width` wide, pinned to the track's ends. `nil` for a bar with no
    /// width, which has no points.
    public static func seekTime(atX x: CGFloat, width: CGFloat, duration: TimeInterval) -> TimeInterval? {
        guard width > 0, duration.isFinite, duration > 0 else { return nil }
        return min(max(Double(x / width), 0), 1) * duration
    }

    /// A reading at `seconds`, anchored `now`: what the bar shows the moment
    /// a seek is sent, before the player republishes its own.
    public func seeked(to seconds: TimeInterval, at now: Date) -> PlaybackPosition {
        PlaybackPosition(
            checkedElapsed: min(max(seconds, 0), duration), duration: duration, anchoredAt: now
        )
    }

    private init(checkedElapsed: TimeInterval, duration: TimeInterval, anchoredAt: Date) {
        self.elapsed = checkedElapsed
        self.duration = duration
        self.anchoredAt = anchoredAt
    }
}
