import AppKit
@preconcurrency import ApplicationServices

/// Accessibility is needed for two things: global key events for the HUD
/// module, and drag detection for the shelf. Clipboard and the shelf drop
/// target need no permission and always work.
@MainActor
public enum Permissions {

    public static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Triggers the system prompt. Only call this from onboarding, where the
    /// user has just been told why it is needed.
    public static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    public static func openAccessibilitySettings() {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )!
        NSWorkspace.shared.open(url)
    }
}
