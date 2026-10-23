import Foundation

/// The one-time welcome card in the open panel (2026-10-24).
///
/// There is no Dock icon, no onboarding window since that was removed with
/// the HUD, and no shortcut until one is chosen — so on a first run nothing
/// says that hovering peeks, that the notch opens, or that files can be
/// dropped on it. The card says so once, in the panel the user just opened,
/// rather than in a window of its own that would be one more thing to close.
///
/// Every decision lives here, as pure functions of the flag and the state,
/// so the view only arranges and the delegate only persists.
public enum WelcomeCard {

    /// Whether the card is on screen.
    ///
    /// The open panel only, and only an open somebody asked for — the notch
    /// tap, the shortcut, or the menu's "Show Welcome Again", which opens as a
    /// tap. A peek fires unprompted and lasts a glance; a hover-open is a
    /// pointer crossing the notch; a swipe can begin as a scroll; a drop is
    /// someone busy dragging, whose file the card would cover. A card in any
    /// of those would be read by nobody, and closing it would spend the one
    /// showing it gets. Those opens leave the flag alone, so the card waits
    /// for the first open that was asked for.
    ///
    /// Never on the camera tab. Showing the tab starts the capture session
    /// (`AppDelegate.syncCameraVisibility`), and an opaque card over a live
    /// camera hides the preview and the very controls that account for the
    /// light being on.
    public static func isShown(seen: Bool, in state: NotchState, openedBy reason: PanelOpenReason?) -> Bool {
        guard !seen, case .open(let tab) = state, tab != .camera else { return false }
        return reason?.isExplicit == true
    }

    /// Whether a transition counts as having read the card.
    ///
    /// Leaving a panel that showed it does: the user saw it and moved on, and
    /// showing it again on every open until a button is pressed would turn
    /// a welcome into a nag. So does a tab switch — the card's last line
    /// points at the tabs, and a user who tries one should see the tab, not
    /// the same card again; the card covers every body, so keeping it would
    /// make the tabs look broken.
    ///
    /// Not a drag arriving (`.receiving`): that is someone dragging, not
    /// someone who read anything. The card yields to the drop target and the
    /// flag stays clear for the next asked-for open. A state that never
    /// showed the card dismisses nothing.
    public static func isDismissed(
        seen: Bool,
        from previous: NotchState,
        openedBy reason: PanelOpenReason?,
        to next: NotchState
    ) -> Bool {
        guard isShown(seen: seen, in: previous, openedBy: reason) else { return false }
        return next != previous && next != .receiving
    }

    /// What the card says, in order.
    ///
    /// Only gestures the app has, as the README's Usage table lists them.
    /// There is no sideways swipe between tabs — a sideways swipe on the
    /// music peek skips tracks — so the tabs line says where they are and how
    /// the strip closes the panel, not a gesture that would do nothing.
    public static let tips: [WelcomeTip] = [
        WelcomeTip(symbolName: "cursorarrow.rays",
                   text: "Rest on the notch to peek at what\u{2019}s playing or what just changed."),
        WelcomeTip(symbolName: "hand.tap",
                   text: "Click it, or swipe down with two fingers, to open this panel."),
        WelcomeTip(symbolName: "arrow.down.doc",
                   text: "Drag files onto the notch to keep them on the shelf."),
        WelcomeTip(symbolName: "square.grid.2x2",
                   text: "Tabs are the icons up top. Swipe up on them to close."),
    ]
}

/// One line of the welcome card: an SF Symbol and a sentence.
public struct WelcomeTip: Equatable, Sendable {
    public let symbolName: String
    public let text: String

    public init(symbolName: String, text: String) {
        self.symbolName = symbolName
        self.text = text
    }
}
