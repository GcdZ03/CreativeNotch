import AppKit
import CoreGraphics

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
/// continuously, and this one fires a few dozen times a day.
///
/// A session `CGEventTap` does the listening, not
/// `NSEvent.addGlobalMonitorForEvents`. Instrumenting a live app showed the
/// `NSEvent` monitor delivers **zero** system-defined events on macOS 26,
/// even with Accessibility granted — zero across 1729 recorded level
/// changes. A spike confirmed the tap receives them correctly. Unlike the
/// old monitor, tap creation itself can fail without Accessibility (the
/// old API always returned a token; only delivery was gated). Either way
/// `onKey` never fires, so attribution still fails open exactly as before:
/// the notch shows every change, including keypresses. Doubled feedback,
/// not silence, because silence is indistinguishable from broken.
@MainActor
public final class MediaKeyMonitor {

    public var onKey: () -> Void = {}

    /// Injectable so the lifecycle is testable without Accessibility or a
    /// keyboard.
    var installMonitor: (@escaping () -> Void) -> Any? = { handler in
        MediaKeyMonitor.installEventTap(onKey: handler)
    }

    var removeMonitor: (Any) -> Void = { token in
        MediaKeyMonitor.removeEventTap(token)
    }

    private(set) var isRunning = false
    private var token: Any?

    public init() {}

    public func start() {
        guard !isRunning else { return }
        token = installMonitor { [weak self] in
            self?.onKey()
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
    /// Only the level keys count: volume up/down, mute, brightness up/down.
    /// System-defined events like caps lock, power, eject, and illumination
    /// must not be read as a level change.
    ///
    /// The key-state bits (key down vs. up, repeat presses) are not filtered,
    /// so a single physical press fires `onKey()` for both down and up, plus
    /// repeats while held. This is deliberate: re-stamping the timestamp keeps
    /// the suppression window alive for exactly as long as Apple's overlay is
    /// on screen, which is what we want.
    public static func isMediaKey(subtype: Int, data1: Int) -> Bool {
        guard subtype == 8 else { return false }
        let keyCode = (data1 & 0xFFFF_0000) >> 16
        switch keyCode {
        case 0, 1, 7:   return true   // SOUND_UP, SOUND_DOWN, MUTE
        case 2, 3:      return true   // BRIGHTNESS_UP, BRIGHTNESS_DOWN
        default:        return false
        }
    }

    // MARK: - CGEventTap plumbing

    /// Bridges the tap's C callback — which carries no Swift context of its
    /// own — to this instance's `onKey` closure and its own tap port, so a
    /// tap macOS disabled for being slow or under load can re-enable
    /// itself from inside the callback. Deliberately not the class itself:
    /// a `@convention(c)` callback cannot capture anything, so this is
    /// threaded through via the `userInfo`/`refcon` parameter instead of a
    /// shared global.
    ///
    /// Not `@MainActor`: it must be constructible and passable across the
    /// C boundary before any actor hop, and the callback that reads it
    /// documents separately why the read itself is safe on the main
    /// thread.
    final class TapContext: @unchecked Sendable {
        let onKey: () -> Void
        /// Set once, immediately after `CGEvent.tapCreate` succeeds and
        /// before the tap is enabled — so the callback can never observe
        /// it as `nil` while the tap is live.
        var port: CFMachPort?
        init(onKey: @escaping () -> Void) { self.onKey = onKey }
    }

    /// Everything `removeEventTap` needs to fully tear the tap down: the
    /// port to invalidate, the run loop source to remove, and the retained
    /// context to release. A plain opaque token — rather than exposing the
    /// raw `CFMachPort` through the `installMonitor`/`removeMonitor` seam —
    /// so that seam, and the identity test that depends on it
    /// (`stoppingRemovesTheSameTokenThatStartInstalled`), stay indifferent
    /// to how the real installer happens to be implemented.
    final class EventTapToken {
        let port: CFMachPort
        let runLoopSource: CFRunLoopSource
        let context: Unmanaged<TapContext>
        init(port: CFMachPort, runLoopSource: CFRunLoopSource, context: Unmanaged<TapContext>) {
            self.port = port
            self.runLoopSource = runLoopSource
            self.context = context
        }
    }

    /// Installs a `.listenOnly` session event tap for `NX_SYSDEFINED`
    /// events. `.listenOnly` is mandatory: consuming these events would
    /// break the user's volume and brightness keys system-wide.
    private static func installEventTap(onKey: @escaping () -> Void) -> Any? {
        let context = TapContext(onKey: onKey)
        let unmanagedContext = Unmanaged.passRetained(context)

        let mask = CGEventMask(1 << 14)   // NX_SYSDEFINED
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: mediaKeyEventTapCallback,
            userInfo: unmanagedContext.toOpaque()
        ) else {
            unmanagedContext.release()
            return nil
        }

        context.port = tap

        guard let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            unmanagedContext.release()
            return nil
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        return EventTapToken(port: tap, runLoopSource: runLoopSource, context: unmanagedContext)
    }

    private static func removeEventTap(_ token: Any) {
        guard let token = token as? EventTapToken else { return }
        CGEvent.tapEnable(tap: token.port, enable: false)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), token.runLoopSource, .commonModes)
        CFMachPortInvalidate(token.port)
        token.context.release()
    }
}

/// The tap's C callback. Must be a plain top-level function with no
/// captures so it converts to a `CGEventTapCallBack`
/// (`@convention(c)`); everything it needs comes through `refcon`.
///
/// `CGEventTapCreate`'s callback runs synchronously on whichever run loop
/// its source was added to — `CFRunLoopGetMain()`, here — so this always
/// executes on the main thread. `MainActor.assumeIsolated` documents that
/// directly rather than hopping through a `Task`, the same pattern
/// `VolumeObserver` uses for its CoreAudio listener, which is likewise
/// guaranteed to run on `DispatchQueue.main`.
private func mediaKeyEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    cgEvent: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(cgEvent) }
    let context = Unmanaged<MediaKeyMonitor.TapContext>.fromOpaque(refcon).takeUnretainedValue()

    // macOS disables a tap it judges slow or under load, delivering one of
    // these instead of a real event. Re-enabling here is what stops the
    // monitor from dying silently mid-session — the same silent-failure
    // shape this module has hit before.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let port = context.port {
            CGEvent.tapEnable(tap: port, enable: true)
        }
        return Unmanaged.passUnretained(cgEvent)
    }

    guard let nsEvent = NSEvent(cgEvent: cgEvent) else { return Unmanaged.passUnretained(cgEvent) }
    let subtype = Int(nsEvent.subtype.rawValue)
    let data1 = nsEvent.data1

    MainActor.assumeIsolated {
        guard MediaKeyMonitor.isMediaKey(subtype: subtype, data1: data1) else { return }
        context.onKey()
    }

    // `.listenOnly` never consumes: always return the event unmodified.
    return Unmanaged.passUnretained(cgEvent)
}
