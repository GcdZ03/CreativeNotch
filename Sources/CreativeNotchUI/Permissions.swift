import AppKit
@preconcurrency import ApplicationServices

/// Accessibility is needed for two things: global key events for the HUD
/// module, and drag detection for the shelf. Clipboard and the shelf drop
/// target need no permission and always work.
///
/// `@preconcurrency import ApplicationServices` is what silences the
/// Swift 6 strict-concurrency error on `kAXTrustedCheckOptionPrompt` (a C
/// global the compiler otherwise flags as "not concurrency-safe because it
/// involves shared mutable state") — `ApplicationServices` predates
/// Swift's concurrency checking and isn't itself audited, so this is the
/// standard escape hatch for that C-interop diagnostic.
///
/// `@MainActor` on this type is a separate, deliberate design choice, not
/// something the compiler forced: every current and foreseeable caller
/// (`MenuBarController`, `OnboardingView`, `AppDelegate`) is already
/// main-actor-bound, and `AXIsProcessTrusted()`'s result is UI-adjacent
/// state that only matters to code updating UI. Isolating it here means
/// any future caller that isn't already on the main actor will need to
/// `await` a hop onto it to read `isAccessibilityTrusted` or call the
/// other members.
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
