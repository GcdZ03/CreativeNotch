import AppKit
import ApplicationServices
import CreativeNotchCore

/// Reads how far an app's menus reach, for "Keep clear of app menus"
/// (2026-10-26).
///
/// A seam like `BluetoothAccess`: the delegate holds a sandbox that is never
/// trusted and reads nothing, so no test can put the Accessibility prompt on
/// screen or read the developer's apps. Only `configureForRealLaunch()`
/// hands it `SystemAppMenuReader`.
@MainActor
protocol AppMenuReader: AnyObject {
    /// Whether macOS lets this app read other apps' menus. Reading it never
    /// prompts.
    var isTrusted: Bool { get }
    /// Shows macOS's Accessibility prompt, which offers System Settings. The
    /// answer comes later, there, and is read from `isTrusted` next time.
    func requestTrust()
    /// How far from its display's left edge `pid`'s menus reach
    /// (`AppMenus.end`), or `nil` when there is nothing to read.
    func menusEnd(of pid: pid_t) -> CGFloat?
}

/// The default: never trusted, never prompts, reads nothing.
final class SandboxAppMenuReader: AppMenuReader {
    var isTrusted: Bool { false }
    func requestTrust() {}
    func menusEnd(of pid: pid_t) -> CGFloat? { nil }
}

/// The real reader, through the Accessibility API.
///
/// Asked once per app switch, and only while the setting is on and trusted
/// -- never polled. Each item's frame is two attribute reads in one call; a
/// menu bar is a dozen or so items.
final class SystemAppMenuReader: AppMenuReader {
    /// How long one Accessibility request may wait for an app to answer. Set
    /// on the system-wide element, so it applies to every request this app
    /// makes. The default is six seconds -- an app that hangs as it comes
    /// forward would hang the notch with it -- and the reads happen on the
    /// main thread. Measured 2026-10-26: an awake app answers a whole menu
    /// bar in well under 0.1s; one in App Nap may not answer at all until it
    /// wakes, and the app being read has just come forward, so it is awake.
    /// The margin is for an app busy coming forward.
    static let messagingTimeout: Float = 0.25

    /// System Settings, Privacy & Security, Accessibility.
    static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    )!

    init() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), Self.messagingTimeout)
    }

    var isTrusted: Bool { AXIsProcessTrusted() }

    func requestTrust() {
        // The key's value, spelled out: `kAXTrustedCheckOptionPrompt` is a
        // global `var`, which strict concurrency will not read.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func menusEnd(of pid: pid_t) -> CGFloat? {
        let app = AXUIElementCreateApplication(pid)
        guard let bar = Self.element(app, kAXMenuBarAttribute),
              let items = Self.value(bar, kAXChildrenAttribute) as? [AXUIElement]
        else { return nil }
        return AppMenus.end(itemFrames: items.compactMap(Self.frame(of:)), screens: Self.screenFrames)
    }

    /// Every screen's frame in the window server's global space, top-left
    /// origin, which is the space Accessibility reports in: flipped about the
    /// primary screen, the one with the menu bar origin.
    private static var screenFrames: [CGRect] {
        guard let primary = NSScreen.screens.first else { return [] }
        return NSScreen.screens.map { screen in
            CGRect(
                x: screen.frame.minX,
                y: primary.frame.maxY - screen.frame.maxY,
                width: screen.frame.width,
                height: screen.frame.height
            )
        }
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = value(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func frame(of item: AXUIElement) -> CGRect? {
        var values: CFArray?
        let attributes = [kAXPositionAttribute, kAXSizeAttribute] as CFArray
        guard AXUIElementCopyMultipleAttributeValues(item, attributes, [], &values) == .success,
              let pair = values as? [CFTypeRef], pair.count == 2
        else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard CFGetTypeID(pair[0]) == AXValueGetTypeID(), CFGetTypeID(pair[1]) == AXValueGetTypeID(),
              AXValueGetValue(pair[0] as! AXValue, .cgPoint, &origin),
              AXValueGetValue(pair[1] as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }
}
