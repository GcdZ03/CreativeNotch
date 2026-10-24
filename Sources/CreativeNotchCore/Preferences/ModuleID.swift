import Foundation

/// The modules a person can switch off.
///
/// **The raw values are the defaults keys' middle segment, so they are a
/// compatibility surface in the same sense `Tab`'s are — and unlike `Tab`'s,
/// they are one today rather than retroactively.** Renaming a case does not
/// migrate the preference behind it; it abandons it. Because an absent key
/// resolves to *on* (`PreferenceKeys.resolveEnabled`), the symptom of a rename
/// is "the module I turned off is back", with nothing failing anywhere.
///
/// Hyphenated rather than camelCased so a key reads as one scheme rather than
/// two: `module.media-metadata.enabled`, not `module.mediaMetadata.enabled`.
public enum ModuleID: String, CaseIterable, Equatable, Sendable {
    case shelf
    case clipboard
    case mediaMetadata = "media-metadata"
    case mediaControls = "media-controls"
    case power
    case timer
    case hotkey
    case camera
    case captureIndicator = "capture-indicator"
    /// AirPods and other audio Bluetooth devices connecting (2026-10-24).
    case bluetooth

    /// What an absent key means for this module.
    ///
    /// On for everything that needs no grant and costs nothing at rest.
    /// **Bluetooth alerts ship off**: switching them on is what asks macOS
    /// for Bluetooth access, and nothing in this app is allowed to prompt
    /// at launch for a feature nobody chose (see Permissions in
    /// `ARCHITECTURE.md`). Read through `PreferenceKeys.resolveEnabled`'s
    /// `shippedDefault`, so a mistyped value reads as off too.
    public var shippedDefault: Bool {
        switch self {
        case .bluetooth: return false
        default:         return true
        }
    }
}
