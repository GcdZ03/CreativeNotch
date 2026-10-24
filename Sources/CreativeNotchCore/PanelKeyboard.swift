import Foundation

/// Why the panel is open, recorded as it opens.
///
/// Exists for one decision: whether the open may take keyboard focus. Taking
/// it costs whatever the person was typing in its insertion point, so it is
/// spent only on an open somebody *asked for*. The notch tap and the global
/// shortcut are that; a pointer resting on the notch is not — hover-open must
/// never steal keystrokes from an editor the pointer happened to cross.
///
/// A swipe and a drop stay ambient too. A swipe is deliberate, but it is a
/// pointer gesture that can begin as a scroll near the top of the screen, and
/// a drop is someone busy dragging, not about to type. A click anywhere in the
/// panel makes it key regardless, so neither loses the keyboard for long.
public enum PanelOpenReason: Equatable, Sendable {
    case tap
    case hotKey
    case hover
    case swipe
    case drop
    /// A bare transition with no route behind it — a preview, a test.
    case unspecified

    public var isExplicit: Bool {
        switch self {
        case .tap, .hotKey:                         return true
        case .hover, .swipe, .drop, .unspecified:   return false
        }
    }
}

/// When the panel takes keyboard focus.
///
/// Pure, so the rule is testable without a window server — `makeKey` on an
/// offscreen panel in a headless suite proves nothing.
public enum PanelFocus {
    /// Only while open, and then either because the open was explicit or
    /// because the tab is the timer. The timer's custom-minutes field needs
    /// the keyboard however the panel got there — that was the original and,
    /// until keyboard control, the only reason the panel could become key.
    ///
    /// Giving focus back is not decided here: it happens once the panel
    /// leaves `.open`, never on a tab switch (see `AppDelegate.syncKeyWindow`).
    public static func shouldTakeKey(for state: NotchState, openedBy reason: PanelOpenReason?) -> Bool {
        guard case .open(let tab) = state else { return false }
        return tab == .timer || reason?.isExplicit == true
    }
}

/// A key the open panel understands, already decoded from the event.
///
/// Decoding (`NotchPanel.panelKey`) stays in the UI target, which owns
/// `NSEvent`; what a key *does* lives here, where it is testable.
public enum PanelKey: Equatable, Sendable {
    case escape
    /// ⌘ plus a number-row digit, 1-based as printed on the key.
    case commandDigit(Int)
}

public enum PanelKeyAction: Equatable, Sendable {
    case close
    case select(Tab)
}

public enum PanelKeyboard {
    /// What `key` does in `state`, or `nil` when it does nothing and should be
    /// passed on.
    ///
    /// `visible` is `TabVisibility.visible(...)`, never `Tab.allCases`: ⌘N
    /// counts the tabs the bar actually draws, so a switched-off module never
    /// leaves a hole in the numbering and ⌘2 is always the second icon.
    ///
    /// Only an open panel answers. A peek is ambient and `.receiving` is a
    /// drag in flight — Esc tearing down a drop target mid-drag is exactly
    /// what the dismissal paths are careful never to do.
    public static func action(for key: PanelKey, in state: NotchState, visible: [Tab]) -> PanelKeyAction? {
        guard case .open = state else { return nil }
        switch key {
        case .escape:
            return .close
        case .commandDigit(let n):
            guard visible.indices.contains(n - 1) else { return nil }
            return .select(visible[n - 1])
        }
    }
}
