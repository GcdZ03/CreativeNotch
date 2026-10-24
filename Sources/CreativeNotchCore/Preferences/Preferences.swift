import Foundation

/// Which modules are switched on.
///
/// A value, never a reference. The switchboard holds one, `AppState` publishes
/// one, and a change is a whole new `Preferences` rather than a mutation
/// observed from two places — which is what keeps "what is enabled right now"
/// answerable by reading one field instead of by asking a controller.
///
/// One field per module rather than a dictionary: a dictionary makes a missing
/// key a runtime question, and the whole point of `§6` is that "missing" is
/// decided once, at the boundary, by `PreferenceKeys.resolveEnabled`.
public struct Preferences: Equatable, Sendable {
    public var shelf: Bool
    public var clipboard: Bool
    public var mediaMetadata: Bool
    public var mediaControls: Bool
    public var power: Bool
    public var timer: Bool
    public var hotkey: Bool
    public var camera: Bool
    public var captureIndicator: Bool
    public var bluetooth: Bool

    public init(
        shelf: Bool = true,
        clipboard: Bool = true,
        mediaMetadata: Bool = true,
        mediaControls: Bool = true,
        power: Bool = true,
        timer: Bool = true,
        hotkey: Bool = true,
        camera: Bool = true,
        captureIndicator: Bool = true,
        bluetooth: Bool = true
    ) {
        self.shelf = shelf
        self.clipboard = clipboard
        self.mediaMetadata = mediaMetadata
        self.mediaControls = mediaControls
        self.power = power
        self.timer = timer
        self.hotkey = hotkey
        self.camera = camera
        self.captureIndicator = captureIndicator
        self.bluetooth = bluetooth
    }

    /// Everything on. What the switchboard holds before `apply()` has read
    /// anything, so constructing a delegate reads no defaults.
    public static let allEnabled = Preferences()

    /// The shipped state, and what a domain with no keys in it resolves to:
    /// every module at its `ModuleID.shippedDefault`. Equal to `allEnabled`
    /// until Bluetooth alerts, the first module to ship off.
    public static let shipped: Preferences = {
        var preferences = Preferences()
        for module in ModuleID.allCases { preferences[module] = module.shippedDefault }
        return preferences
    }()

    public subscript(module: ModuleID) -> Bool {
        get {
            switch module {
            case .shelf:         return shelf
            case .clipboard:     return clipboard
            case .mediaMetadata: return mediaMetadata
            case .mediaControls: return mediaControls
            case .power:         return power
            case .timer:         return timer
            case .hotkey:        return hotkey
            case .camera:        return camera
            case .captureIndicator: return captureIndicator
            case .bluetooth:     return bluetooth
            }
        }
        set {
            switch module {
            case .shelf:         shelf = newValue
            case .clipboard:     clipboard = newValue
            case .mediaMetadata: mediaMetadata = newValue
            case .mediaControls: mediaControls = newValue
            case .power:         power = newValue
            case .timer:         timer = newValue
            case .hotkey:        hotkey = newValue
            case .camera:        camera = newValue
            case .captureIndicator: captureIndicator = newValue
            case .bluetooth:     bluetooth = newValue
            }
        }
    }
}
