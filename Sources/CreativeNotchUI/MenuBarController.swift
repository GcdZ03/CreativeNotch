import AppKit

/// The only settings surface. A four-module personal tool does not need a
/// preferences window.
///
/// `NSObject` (not a plain `final class`) because target-action —
/// `accessibility.target = self` / `#selector(openOnboarding)` — requires
/// it; a plain Swift class has no Objective-C runtime identity for the
/// selector to resolve against.
@MainActor
public final class MenuBarController: NSObject {

    private var item: NSStatusItem?
    private var accessibilityItem: NSMenuItem?
    private let onShowOnboarding: () -> Void

    public init(onShowOnboarding: @escaping () -> Void) {
        self.onShowOnboarding = onShowOnboarding
    }

    public func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "rectangle.topthird.inset.filled",
            accessibilityDescription: "CreativeNotch"
        )

        let menu = NSMenu()
        menu.delegate = self

        let accessibility = NSMenuItem(
            title: Self.accessibilityTitle(trusted: Permissions.isAccessibilityTrusted),
            action: #selector(openOnboarding),
            keyEquivalent: ""
        )
        accessibility.target = self
        menu.addItem(accessibility)
        self.accessibilityItem = accessibility

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit CreativeNotch",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quit)

        item.menu = menu
        self.item = item
    }

    /// Pure formatting, pulled out of `Permissions.isAccessibilityTrusted`'s
    /// call site so it can be tested without touching Accessibility
    /// permission state.
    public static func accessibilityTitle(trusted: Bool) -> String {
        trusted
            ? "Accessibility: granted"
            : "Accessibility: not granted — set up…"
    }

    @objc private func openOnboarding() {
        onShowOnboarding()
    }
}

extension MenuBarController: NSMenuDelegate {
    /// Refreshes the Accessibility line each time the menu opens, so a
    /// permission grant made in System Settings while the app was already
    /// running shows up without polling `Permissions.isAccessibilityTrusted`
    /// on a timer.
    public func menuWillOpen(_ menu: NSMenu) {
        accessibilityItem?.title = Self.accessibilityTitle(trusted: Permissions.isAccessibilityTrusted)
    }
}
