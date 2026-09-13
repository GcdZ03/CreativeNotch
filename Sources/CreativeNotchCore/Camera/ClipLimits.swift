import Foundation

/// Ceilings on a recording.
///
/// A clip written to the shelf competes for the same disk as everything else
/// in it, and the shelf evicts by trashing real files. An unbounded recording
/// is therefore not merely large; it is a way to lose other things.
public enum ClipLimits {

    /// Five minutes. Long enough for anything a notch-sized recorder is for,
    /// short enough that forgetting one running costs a file rather than a
    /// disk.
    public static let maxDuration: TimeInterval = 300

    /// 512 MB. `AVCaptureMovieFileOutput` enforces this itself and stops
    /// cleanly at the limit, which is why it is set on the output rather than
    /// checked in a timer -- a size check on a timer would be exactly the kind
    /// of polling this project refuses.
    public static let maxBytes: Int64 = 512 * 1024 * 1024

    /// Whether a recording has reached its limit.
    ///
    /// Only for display -- the output enforces both ceilings itself. This
    /// exists so the view can warn before it happens rather than appearing to
    /// stop for no reason.
    public static func isNearingLimit(elapsed: TimeInterval) -> Bool {
        elapsed >= maxDuration - 30
    }
}
