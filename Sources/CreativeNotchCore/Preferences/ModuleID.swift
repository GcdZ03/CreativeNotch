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
    case calendar
    case colorPicker = "color-picker"

    /// What an absent key means for this module.
    ///
    /// On for every module but two. **The calendar and Bluetooth alerts ship
    /// off** because neither can work without asking for something: the
    /// calendar's glance needs the Calendars and Reminders grants, and
    /// Bluetooth alerts need Bluetooth access. A permission prompt belongs to
    /// the moment someone switches the feature on, never to a launch, and
    /// never to a feature nobody chose (see Permissions in
    /// `ARCHITECTURE.md`). Every other module either needs no grant or, like
    /// the camera, asks only when its tab is opened -- and costs nothing at
    /// rest.
    ///
    /// Read by `PreferencesStore.load` through `resolveEnabled`'s
    /// `shippedDefault`, so "absent" is still decided in one function -- and
    /// a mistyped value reads as off too.
    public var shippedDefault: Bool {
        switch self {
        case .bluetooth, .calendar: return false
        default:                    return true
        }
    }
}
