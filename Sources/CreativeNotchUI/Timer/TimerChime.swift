import AppKit

/// One built-in alert, played once.
///
/// No bundled asset to ship or license, and `NSSound` follows the system
/// alert volume, so a muted Mac stays muted. Played once rather than
/// repeating: the peek already carries the unacknowledged signal, and a
/// looping alarm from a menu-bar utility is an uninstall.
///
/// Failure is silent by design — the peek is the primary signal and the
/// sound only amplifies it, so a missing system sound must never take the
/// notification down with it.
enum TimerChime {
    static func play() {
        NSSound(named: "Glass")?.play()
    }
}
