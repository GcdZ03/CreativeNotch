import Foundation

/// A MediaRemote transport command.
///
/// The raw values are MediaRemote's own command numbers. They are not
/// documented by Apple and the compiler cannot check them, so they appear
/// exactly once — here — rather than as bare integers at call sites, and
/// `MediaCommandTests` pins them against what has been verified against a
/// real player.
///
/// All three constants have been sent against a real player (Spotify) with
/// its AppleScript state as independent ground truth, and confirmed to
/// produce the expected effect.
///
/// `3` (stop) is absent on purpose: nothing in this module stops playback.
/// The gap in the numbering is deliberate, not an oversight.
public enum MediaCommand: Int32, CaseIterable, Equatable, Sendable {
    case togglePlayPause = 2
    case nextTrack = 4
    case previousTrack = 5
}
