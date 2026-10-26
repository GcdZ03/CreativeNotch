import CoreGraphics
import Foundation

/// Which display the notch lives on: "Show on" in Settings (2026-10-24).
///
/// **Following focus is the default** because it is what the app did before
/// the setting existed: the panel follows the focused window, and is placed
/// again whenever focus may have moved -- an app coming forward or a Space
/// switch (`screenOnFocusChange`). On one display that is
/// invisible; on several it makes the pill hop to whichever display was
/// clicked last, which is what pinning is for.
///
/// **A specific display is remembered by its UUID, not its display id.** The
/// `CGDirectDisplayID` is the window server's number for a display *this
/// session* and may change across a reboot or a reconnection;
/// `CGDisplayCreateUUIDFromDisplayID` names the same physical display every
/// time. The display's name is stored beside it only so Settings can still
/// say what is pinned while it is unplugged -- it never takes part in
/// finding the display.
///
/// **A pinned display that is not connected is waited for, not forgotten.**
/// The choice stays as it was, the panel goes to the built-in display (then
/// the main, then the first) in the meantime, and the screen-parameter change
/// that comes with plugging it back in finds it again. Nothing is polled:
/// the rule is asked afresh on every change, and the answer is whatever is
/// connected then.
public enum DisplayChoice: Hashable, Sendable {
    case focusedWindow
    case builtIn
    /// One display, by `CGDisplayCreateUUIDFromDisplayID` in uppercase, and
    /// its `NSScreen.localizedName` when it was picked.
    case display(uuid: String, name: String)

    public static let `default`: DisplayChoice = .focusedWindow

    /// The choices that exist whatever is plugged in, in menu order.
    public static let standardChoices: [DisplayChoice] = [.focusedWindow, .builtIn]

    /// The id of the screen the notch belongs on, or `nil` with no screens.
    ///
    /// A missing built-in display -- clamshell, a Mac mini, or the lid just
    /// closed -- falls back to following focus rather than leaving the notch
    /// nowhere, and no main screen (an accessory app may have no key window)
    /// falls back to the first, which is the one with the menu bar. A
    /// disconnected display is simply absent from `screens`, so the next
    /// call answers from what is left.
    ///
    /// A pinned display that is absent falls back to the built-in display
    /// before focus: a fallback that followed focus would hop with every
    /// screen change while the user is waiting for their display to come
    /// back, which is what they pinned to avoid.
    public func screen(in screens: [ScreenDescriptor]) -> CGDirectDisplayID? {
        let focused = (screens.first(where: \.isMain) ?? screens.first)?.id
        let builtIn = screens.first(where: \.isBuiltIn)?.id
        switch self {
        case .focusedWindow:
            return focused
        case .builtIn:
            return builtIn ?? focused
        case .display(let uuid, _):
            return screens.first(where: { $0.uuid == uuid })?.id ?? builtIn ?? focused
        }
    }

    /// Whether focus moving -- another app coming forward, a Space switch --
    /// is a reason to place the panel again. Pinned, it is not: the pinned
    /// display is the same display wherever focus is, and asking on every
    /// Cmd-Tab is work the rule says not to do.
    public var followsActivation: Bool { self == .focusedWindow }

    /// This choice with a pinned display's stored name brought up to date,
    /// if that display is connected under another name now.
    ///
    /// The name is only for saying what is pinned while the display is
    /// unplugged, and it is recorded when the display is picked -- so a
    /// display renamed afterwards (in System Settings, or a monitor that
    /// reports a new name after a firmware update) went on being called by
    /// its old name. The UUID is what finds the display, so this never
    /// changes *which* display is pinned. An unplugged pin keeps its name,
    /// the only record left, and a screen reporting an empty name is not
    /// taken as a rename.
    public func refreshingName(from screens: [ScreenDescriptor]) -> DisplayChoice {
        guard case .display(let uuid, let name) = self,
              let screen = screens.first(where: { $0.uuid == uuid }),
              !screen.name.isEmpty, screen.name != name
        else { return self }
        return .display(uuid: uuid, name: screen.name)
    }

    /// The screen a change of focus moves the notch to, or `nil` to leave it
    /// where it is.
    ///
    /// Focus is where the frontmost app's frontmost window is
    /// (`FocusedWindow.frame`): the screen holding most of it. Not
    /// `NSScreen.main`, which lags an app switch and put the notch on the
    /// screen just left (2026-10-26).
    ///
    /// With no such window -- an accessory app, or Finder showing only the
    /// desktop -- there is no news about where focus is, so the notch stays,
    /// as it did when there was no main screen. Stricter than `screen(in:)`,
    /// which must put the panel somewhere at launch and on a screen change
    /// and so falls back to the first screen.
    public func screenOnFocusChange(in screens: [ScreenDescriptor], focusedWindow: CGRect?) -> CGDirectDisplayID? {
        guard followsActivation, let window = focusedWindow,
              let screen = screens.max(by: { $0.overlap(with: window) < $1.overlap(with: window) }),
              screen.overlap(with: window) > 0
        else { return nil }
        return screen.id
    }
}

// MARK: - Storage

extension DisplayChoice: RawRepresentable {
    private static let displayPrefix = "display:"

    /// What is on disk under `PreferenceKeys.showOn`. The two general choices
    /// keep the spellings they shipped with; a pinned display is
    /// `display:<UUID>:<name>`. The UUID never contains a colon, so the name
    /// may, and is read as everything after the second one.
    public var rawValue: String {
        switch self {
        case .focusedWindow: return "focused-window"
        case .builtIn: return "built-in"
        case .display(let uuid, let name): return "\(Self.displayPrefix)\(uuid):\(name)"
        }
    }

    /// `nil` for anything that names no choice, a malformed UUID included,
    /// so `PreferenceKeys.resolveDisplayChoice` reads it as the default. The
    /// name is optional -- `display:<UUID>` typed by hand still pins -- and a
    /// lowercase UUID reads as the uppercase spelling the system reports.
    public init?(rawValue: String) {
        switch rawValue {
        case "focused-window": self = .focusedWindow
        case "built-in": self = .builtIn
        default:
            guard rawValue.hasPrefix(Self.displayPrefix) else { return nil }
            let rest = rawValue.dropFirst(Self.displayPrefix.count)
            let parts = rest.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard let uuid = parts.first.flatMap({ UUID(uuidString: String($0)) }) else { return nil }
            self = .display(uuid: uuid.uuidString, name: parts.count > 1 ? String(parts[1]) : "")
        }
    }
}

// MARK: - The Settings menu

extension DisplayChoice {
    /// One entry in the "Show on" menu: the choice it selects, the display
    /// name to show for a specific display (`nil` for the general choices,
    /// which the view words itself), and whether that display is plugged in.
    public struct Option: Hashable, Sendable {
        public var choice: DisplayChoice
        public var name: String?
        public var isConnected: Bool

        public init(choice: DisplayChoice, name: String?, isConnected: Bool) {
            self.choice = choice
            self.name = name
            self.isConnected = isConnected
        }
    }

    /// The menu for the screens connected now, with `current` selected.
    ///
    /// The built-in display is left out of the per-display entries: it is
    /// already "Built-in display", and two entries for one screen that
    /// behave differently only when it is gone is a choice nobody can make
    /// from the menu. This is deliberate, not a gap: `.builtIn` already is
    /// the specific choice for the laptop screen, so no `.display` pin to a
    /// built-in screen is ever offered. A screen with no UUID is left out
    /// too, since a pin to it could never be found again.
    ///
    /// A pinned display that is connected is tagged with the stored choice
    /// itself, so the menu shows it selected even if its name changed since;
    /// one that is not connected stays at the end, marked, so the selection
    /// is still visible rather than the menu showing nothing chosen.
    public static func options(for screens: [ScreenDescriptor], current: DisplayChoice) -> [Option] {
        var options = standardChoices.map { Option(choice: $0, name: nil, isConnected: true) }
        var pinnedUUID: String?
        if case .display(let uuid, _) = current { pinnedUUID = uuid }
        var pinnedIsConnected = false
        for screen in screens where !screen.isBuiltIn {
            guard let uuid = screen.uuid else { continue }
            let choice: DisplayChoice
            if uuid == pinnedUUID {
                choice = current
                pinnedIsConnected = true
            } else {
                choice = .display(uuid: uuid, name: screen.name)
            }
            options.append(Option(choice: choice, name: screen.name, isConnected: true))
        }
        if case .display(_, let name) = current, !pinnedIsConnected {
            options.append(Option(choice: current, name: name, isConnected: false))
        }
        return options
    }
}

/// What the screen rule and the "Show on" menu need to know about one
/// display, and nothing else.
///
/// Built from `NSScreen`, `CGDisplayIsBuiltin` and
/// `CGDisplayCreateUUIDFromDisplayID` in the UI target, kept AppKit-free here
/// for the reason `ScreenMetrics` is.
public struct ScreenDescriptor: Equatable, Sendable {
    public var id: CGDirectDisplayID
    public var isBuiltIn: Bool
    /// Holds the key window -- `NSScreen.main`.
    public var isMain: Bool
    /// The display's persistent UUID, uppercase, or `nil` if the system
    /// could not name one. What a pinned choice is matched against.
    public var uuid: String?
    /// `NSScreen.localizedName`, for the menu.
    public var name: String
    /// `NSScreen.frame`, in AppKit's global space: what a focused window is
    /// matched against.
    public var frame: CGRect

    public init(
        id: CGDirectDisplayID, isBuiltIn: Bool, isMain: Bool,
        uuid: String? = nil, name: String = "", frame: CGRect = .zero
    ) {
        self.id = id
        self.isBuiltIn = isBuiltIn
        self.isMain = isMain
        self.uuid = uuid
        self.name = name
        self.frame = frame
    }

    /// How much of `rect` lies on this screen, as an area.
    func overlap(with rect: CGRect) -> CGFloat {
        let shared = frame.intersection(rect)
        return shared.isNull ? 0 : shared.width * shared.height
    }
}
