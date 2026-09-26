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
}
