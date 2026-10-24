import CoreGraphics

/// How large the open panel's text is: "Text size" in Settings (2026-10-24).
///
/// **An app setting, because macOS has no Dynamic Type for this app to
/// follow.** SwiftUI's `dynamicTypeSize` exists on macOS but is not fed from
/// System Settings: probed on macOS 26 it reads `.large` and the body font
/// 13pt, and Accessibility > Display > Text Size there is a per-app list of
/// Apple's own apps, which a third-party accessory app is not on. Reading it
/// would be relying on a value nothing writes.
///
/// **The default is the look from before the setting**, factor one, so that
/// every font and every length routed through `NotchType` comes back
/// unchanged for anyone who never opens the row.
///
/// Three steps rather than a slider: each one is a panel size that was
/// rendered and checked for clipping (`TextSizeRenderingTests`); a
/// continuous range would ship sizes nobody looked at.
public enum TextSize: String, CaseIterable, Sendable {
    case standard = "default"
    case large
    case larger

    public static let `default`: TextSize = .standard

    /// The factor every panel font, every text-holding length and the
    /// panel's own size are multiplied by.
    public var scale: CGFloat {
        switch self {
        case .standard: return 1
        case .large:    return 1.15
        case .larger:   return 1.3
        }
    }
}
