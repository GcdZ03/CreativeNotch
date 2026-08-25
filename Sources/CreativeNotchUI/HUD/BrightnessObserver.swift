import AppKit
import CoreGraphics
import CreativeNotchCore

/// Watches display brightness through the private DisplayServices
/// framework.
///
/// There is no public API for reading brightness. DisplayServices is not
/// permission-gated, and the spike confirmed its change notification fires
/// exactly once per change — unlike CoreAudio's, which fires twice.
///
/// ⚠️ **The callback's `CGDirectDisplayID` argument is `0`**, not a valid
/// display. The signature circulated online is wrong: reading brightness
/// with the passed ID returns status 1000 and writes nothing.
/// `CGMainDisplayID()` is what works. ⚠️ The callback also runs **off the
/// main thread**.
@MainActor
public final class BrightnessObserver {

    public var onChange: (HUDKind) -> Void = { _ in }
    private(set) var isRunning = false

    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Callback = @convention(c) (
        UnsafeMutableRawPointer?, CGDirectDisplayID,
        UnsafeRawPointer?, UnsafeRawPointer?, UnsafeRawPointer?
    ) -> Void
    private typealias Register = @convention(c) (CGDirectDisplayID, UnsafeMutableRawPointer?, Callback) -> Int32
    private typealias Unregister = @convention(c) (CGDirectDisplayID, UnsafeMutableRawPointer?, Callback) -> Int32

    private static let handle = dlopen(
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
        RTLD_NOW
    )

    public static var symbolsAvailable: Bool {
        guard let handle else { return false }
        return dlsym(handle, "DisplayServicesGetBrightness") != nil
            && dlsym(handle, "DisplayServicesRegisterForBrightnessChangeNotifications") != nil
    }

    /// Set while running so the C callback — which carries no context we
    /// can trust — can reach the live observer.
    private nonisolated(unsafe) static weak var active: BrightnessObserver?

    /// The single callback instance passed to both register and
    /// unregister. Two `@convention(c)` closure *literals* are not
    /// guaranteed to share a function pointer even when textually
    /// identical, and DisplayServices matches a registration to remove by
    /// pointer — so a `stop()` that built a fresh literal here could
    /// silently fail to unregister and leak the listener, all while
    /// `isRunning` still flipped to `false` as if it had worked. Hoisting
    /// to one `static let` guarantees `start()` and `stop()` always pass
    /// the identical pointer. (The equivalent bug was found and fixed in
    /// `VolumeObserver` for CoreAudio.)
    private static let changeCallback: Callback = { _, _, _, _, _ in
        // The passed display ID is 0 and unusable, and this runs off the
        // main thread — hop before touching anything.
        Task { @MainActor in
            guard let observer = BrightnessObserver.active,
                  let level = observer.currentLevel() else { return }
            observer.onChange(.brightness(level))
        }
    }

    /// Records of the exact pointer handed to the C API on the last
    /// register/unregister call. Exposed only so tests can prove the two
    /// match without needing a live brightness change to observe it —
    /// `isRunning` alone is a boolean that flips whether or not removal
    /// actually matched, which is exactly how a mismatched `stop()` would
    /// have passed review.
    static private(set) var lastRegisteredCallback: UnsafeRawPointer?
    static private(set) var lastUnregisteredCallback: UnsafeRawPointer?

    public init() {}

    public func start() {
        guard !isRunning, let handle = Self.handle,
              let registerSym = dlsym(handle, "DisplayServicesRegisterForBrightnessChangeNotifications")
        else { return }

        Self.active = self
        let register = unsafeBitCast(registerSym, to: Register.self)
        Self.lastRegisteredCallback = unsafeBitCast(Self.changeCallback, to: UnsafeRawPointer.self)

        if register(CGMainDisplayID(), nil, Self.changeCallback) == 0 {
            isRunning = true
        }
    }

    public func stop() {
        guard isRunning, let handle = Self.handle,
              let unregisterSym = dlsym(handle, "DisplayServicesUnregisterForBrightnessChangeNotifications")
        else { isRunning = false; return }

        let unregister = unsafeBitCast(unregisterSym, to: Unregister.self)
        Self.lastUnregisteredCallback = unsafeBitCast(Self.changeCallback, to: UnsafeRawPointer.self)
        _ = unregister(CGMainDisplayID(), nil, Self.changeCallback)
        Self.active = nil
        isRunning = false
    }

    public func currentLevel() -> Double? {
        guard let handle = Self.handle,
              let sym = dlsym(handle, "DisplayServicesGetBrightness")
        else { return nil }
        let get = unsafeBitCast(sym, to: GetBrightness.self)
        var level: Float = 0
        // CGMainDisplayID(), never the ID handed to the callback.
        guard get(CGMainDisplayID(), &level) == 0 else { return nil }
        return Double(level)
    }
}
