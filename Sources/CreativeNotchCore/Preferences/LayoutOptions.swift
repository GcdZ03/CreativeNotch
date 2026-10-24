import CoreGraphics

/// How wide the open panel is: "Panel width" in Settings (2026-10-24).
///
/// Three steps rather than a slider, for the reason `TextSize` gives: each is
/// a panel that was rendered and checked (`LayoutRenderingTests`), and a
/// continuous range would ship widths nobody looked at.
///
/// A *nominal* width. The text size grows it by the same factor it grows the
/// default, and Compact beside a real notch goes no narrower than the tabs
/// need (`NotchGeometry.panelFrame(for:in:textScale:width:tabCount:)`).
public enum PanelWidth: String, CaseIterable, Sendable {
    case compact
    case standard = "default"
    case wide

    public static let `default`: PanelWidth = .standard

    /// Default is `NotchGeometry.expandedSize.width`, the panel's width from
    /// before the setting. Compact still holds the 212pt music column with a
    /// pane beside it that the timer's 220pt track fits in; Wide gives the
    /// shelf and the clipboard a few more columns without reaching the
    /// status items at the far right of a 14" menu bar.
    public var nominalWidth: CGFloat {
        switch self {
        case .compact:  return 560
        case .standard: return NotchGeometry.expandedSize.width
        case .wide:     return 720
        }
    }
}

/// How round the open panel's bottom corners are: "Corners" in Settings.
///
/// The open panel only. The closed notch's radius approximates the hardware
/// cutout and must keep doing so (`NotchGeometry.notchCornerRadius`), and a
/// peek is sized into the camera housing's band, where a 30pt radius on a
/// 32pt-tall shape would round it into a lozenge.
public enum PanelCorners: String, CaseIterable, Sendable {
    case tight
    case standard = "default"
    case round

    public static let `default`: PanelCorners = .standard

    public var radius: CGFloat {
        switch self {
        case .tight:    return 10
        case .standard: return NotchGeometry.panelCornerRadius
        case .round:    return 30
        }
    }
}

/// Which of the header's two ears holds the tabs: "Tabs" in Settings.
///
/// Named by the screen, left and right, rather than leading and trailing: the
/// ears are either side of a piece of hardware, which does not flip with the
/// language, and the panel's text is English-only for now anyway.
public enum EarSide: String, CaseIterable, Sendable {
    case left
    case right

    public static let `default`: EarSide = .left
}

/// The panel's size and layout options, as one value (2026-10-24).
///
/// One value rather than six properties on `AppState` for the reason `Limits`
/// is one: they are saved together, applied together, and read by one draw,
/// so a partial write is a second way for the domain and the app to disagree.
///
/// **Every default is the look from before the setting**, so someone who
/// never opens the section gets the geometry and the header they always had.
///
/// Costs nothing at rest: nothing here starts, observes or schedules
/// anything. The view reads it on its next draw, and a width change moves
/// the window through `AppDelegate.reposition`, the path a screen change
/// already takes.
public struct LayoutOptions: Equatable, Sendable {
    public var width: PanelWidth
    public var corners: PanelCorners
    public var tabsSide: EarSide

    /// The battery cell beside the gear. The Battery tab, the peeks and the
    /// low-battery warning are unaffected: this is about the header's room,
    /// not about whether the app watches the battery (the module switch is).
    public var showsBattery: Bool

    /// The cover-and-bars badge beside the closed notch while music plays.
    public var showsNowPlayingBadge: Bool

    /// The countdown beside the closed notch. The timer still chimes and
    /// peeks when it ends; only the ambient readout goes.
    public var showsTimerBadge: Bool

    public static let `default` = LayoutOptions()

    public init(
        width: PanelWidth = .default,
        corners: PanelCorners = .default,
        tabsSide: EarSide = .default,
        showsBattery: Bool = true,
        showsNowPlayingBadge: Bool = true,
        showsTimerBadge: Bool = true
    ) {
        self.width = width
        self.corners = corners
        self.tabsSide = tabsSide
        self.showsBattery = showsBattery
        self.showsNowPlayingBadge = showsNowPlayingBadge
        self.showsTimerBadge = showsTimerBadge
    }

    /// The badges `NotchShape.badgeSlot` should pass over. Only the two the
    /// user starts themselves can be in it: see that function for why the
    /// recording dot and the capture indicator never are.
    public var hiddenBadges: Set<BadgeSlot> {
        var hidden: Set<BadgeSlot> = []
        if !showsNowPlayingBadge { hidden.insert(.nowPlaying) }
        if !showsTimerBadge { hidden.insert(.timer) }
        return hidden
    }
}
