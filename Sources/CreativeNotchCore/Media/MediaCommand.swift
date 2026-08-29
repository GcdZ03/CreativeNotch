import Foundation

/// A MediaRemote transport command.
///
/// The raw values are MediaRemote's own command numbers. They are not
/// documented by Apple and the compiler cannot check them, so they appear
/// exactly once — here — rather than as bare integers at call sites, and
/// `MediaCommandTests` pins them against what the spike verified.
///
/// `3` (stop) is absent on purpose: nothing in this module stops playback.
/// The gap in the numbering is deliberate, not an oversight.
public enum MediaCommand: Int32, CaseIterable, Equatable, Sendable {
    case togglePlayPause = 2
    case nextTrack = 4
    case previousTrack = 5

    /// Whether the spike actually sent this command and confirmed the
    /// effect against a real player.
    ///
    /// `togglePlayPause` was confirmed in both directions.
    /// `nextTrack` and `previousTrack` are the same call with a different
    /// constant and are expected to behave identically, but were never
    /// sent — doing so moves the user's queue position. Recorded on the
    /// type so the difference between "proven" and "assumed" survives
    /// past the research document.
    public var isVerified: Bool {
        self == .togglePlayPause
    }
}
