import Foundation

/// How long to wait before restarting the helper, and when to stop trying.
///
/// The helper is a subprocess talking to a private framework; it failing is
/// ordinary rather than exceptional. Retrying forever would be a crash loop
/// nobody notices, so this gives up — and giving up is safe, because
/// transport controls need none of this and keep working.
public enum HelperBackoff {

    public static let maxAttempts = 5

    /// Nothing waits longer than this, however `maxAttempts` changes.
    public static let cap: TimeInterval = 30

    /// The delay before `attempt`, or `nil` when there is no attempt left.
    ///
    /// `nil` means **degrade**, not "retry immediately" — the caller must
    /// not treat an absent delay as zero.
    public static func delay(forAttempt attempt: Int) -> TimeInterval? {
        guard attempt >= 1, attempt <= maxAttempts else { return nil }
        return min(pow(2, Double(attempt - 1)), cap)
    }
}
