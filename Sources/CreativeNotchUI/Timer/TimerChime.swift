import AppKit
import CreativeNotchCore

/// One built-in alert, played once — the one chosen in Settings
/// (2026-10-24), Glass until then, or nothing for "None".
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
    static func play(_ sound: ChimeSound) {
        guard let name = sound.soundName else { return }
        NSSound(named: name)?.play()
    }
}
