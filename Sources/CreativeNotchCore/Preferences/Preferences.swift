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
    public var hud: Bool
    public var clipboard: Bool
    public var mediaMetadata: Bool
    public var mediaControls: Bool
    public var power: Bool
    public var timer: Bool

    public init(
        shelf: Bool = true,
        hud: Bool = true,
        clipboard: Bool = true,
        mediaMetadata: Bool = true,
        mediaControls: Bool = true,
        power: Bool = true,
        timer: Bool = true
    ) {
        self.shelf = shelf
        self.hud = hud
        self.clipboard = clipboard
        self.mediaMetadata = mediaMetadata
        self.mediaControls = mediaControls
        self.power = power
        self.timer = timer
    }

    /// Everything on. The shipped state, and what a domain with no keys in it
    /// resolves to.
    public static let allEnabled = Preferences()

    public subscript(module: ModuleID) -> Bool {
        get {
            switch module {
            case .shelf:         return shelf
            case .hud:           return hud
            case .clipboard:     return clipboard
            case .mediaMetadata: return mediaMetadata
            case .mediaControls: return mediaControls
            case .power:         return power
            case .timer:         return timer
            }
        }
        set {
            switch module {
            case .shelf:         shelf = newValue
            case .hud:           hud = newValue
            case .clipboard:     clipboard = newValue
            case .mediaMetadata: mediaMetadata = newValue
            case .mediaControls: mediaControls = newValue
            case .power:         power = newValue
            case .timer:         timer = newValue
            }
        }
    }
}
