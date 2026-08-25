import AppKit

/// Detects presses of the volume, mute and brightness keys.
///
/// This exists so the notch can stay **silent** when Apple's own HUD is
/// already showing — the one case where the two would genuinely overlap.
/// Nothing exposes whether Apple's HUD is on screen, so the keypress is
/// detected instead.
///
/// It requires Accessibility permission, and it is the only
/// always-installed global monitor in the project. Spec section 3.2 admits
/// it deliberately: the no-polling rule exists to stop monitors that fire
/// continuously, and this one fires a few dozen times a day. If
/// Accessibility is not granted the monitor simply never fires, and
/// attribution fails open — the notch shows every change, including
/// keypresses. Doubled feedback, not silence, because silence is
/// indistinguishable from broken.
@MainActor
public final class MediaKeyMonitor {

    public var onKey: () -> Void = {}

    /// Injectable so the lifecycle is testable without Accessibility or a
    /// keyboard.
    var installMonitor: (@escaping (NSEvent) -> Void) -> Any? = { handler in
        NSEvent.addGlobalMonitorForEvents(matching: [.systemDefined]) { handler($0) }
    }

    var removeMonitor: (Any) -> Void = { NSEvent.removeMonitor($0) }

    private(set) var isRunning = false
    private var token: Any?

    public init() {}

    public func start() {
        guard !isRunning else { return }
        token = installMonitor { [weak self] event in
            guard let self,
                  Self.isMediaKey(subtype: Int(event.subtype.rawValue), data1: event.data1)
            else { return }
            self.onKey()
        }
        isRunning = token != nil
    }

    public func stop() {
        guard isRunning, let token else { isRunning = false; return }
        removeMonitor(token)
        self.token = nil
        isRunning = false
    }

    /// `data1` packs the key code into its high 16 bits.
    ///
    /// Only the level keys count. Keyboard illumination and eject are
    /// system-defined events too, and must not be read as a level change.
    public static func isMediaKey(subtype: Int, data1: Int) -> Bool {
        guard subtype == 8 else { return false }
        let keyCode = (data1 & 0xFFFF_0000) >> 16
        switch keyCode {
        case 0, 1, 7:   return true   // SOUND_UP, SOUND_DOWN, MUTE
        case 2, 3:      return true   // BRIGHTNESS_UP, BRIGHTNESS_DOWN
        default:        return false
        }
    }
}
