import AppKit
import CreativeNotchCore

/// Tells the app when the notch's display enters or leaves a full-screen app
/// (2026-10-17), so it can hide the notch there again.
///
/// Event-driven, like everything else here: it reads the window server's
/// Space list only when `NSWorkspace` says the active Space changed, and at
/// start. Nothing runs in between.
@MainActor
final class FullScreenWatcher {
    var onChange: (Bool) -> Void = { _ in }

    private let center: NotificationCenter
    private let readDisplays: () -> [[String: Any]]?
    private let displayUUID: () -> String?
    private var token: NSObjectProtocol?
    private var last = false

    init(
        center: NotificationCenter = NSWorkspace.shared.notificationCenter,
        readDisplays: @escaping () -> [[String: Any]]?,
        displayUUID: @escaping () -> String?
    ) {
        self.center = center
        self.readDisplays = readDisplays
        self.displayUUID = displayUUID
    }

    func start() {
        stop()
        token = center.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
        evaluate()
    }

    func stop() {
        if let token { center.removeObserver(token) }
        token = nil
    }

    /// Reports only a change: moving between two desktops is not news.
    func evaluate() {
        let now = FullScreenSpaces.isFullScreen(
            displays: readDisplays() ?? [], displayUUID: displayUUID()
        )
        guard now != last else { return }
        last = now
        onChange(now)
    }

    /// `CGSCopyManagedDisplaySpaces`, resolved with `dlsym` like
    /// `SkyLightSpaceServer`: `nil` on a macOS without it, and then the app
    /// simply never hides the notch for full-screen. It only reads.
    static func skyLightReader() -> (() -> [[String: Any]]?)? {
        typealias Connection = @convention(c) () -> Int32
        typealias Copy = @convention(c) (Int32) -> Unmanaged<CFArray>?
        guard
            let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
            let connection = dlsym(handle, "CGSMainConnectionID"),
            let copy = dlsym(handle, "CGSCopyManagedDisplaySpaces")
        else { return nil }
        let cid = unsafeBitCast(connection, to: Connection.self)()
        let copySpaces = unsafeBitCast(copy, to: Copy.self)
        return { copySpaces(cid)?.takeRetainedValue() as? [[String: Any]] }
    }

    /// The window server's identifier for a screen, the key its Space list
    /// is organised by.
    static func uuid(of screen: NSScreen?) -> String? {
        guard let number = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue()
        else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}
