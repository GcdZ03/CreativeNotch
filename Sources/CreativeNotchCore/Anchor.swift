import CoreGraphics

/// Where the panel attaches on a given screen.
///
/// `.notch` is real hardware. `.pill` is synthesised below the menu bar on
/// notchless Macs and external displays — deliberately *not* a fake black
/// notch, which is the thing reviewers single out as jarring in NotchNook.
public enum Anchor: Equatable, Sendable {
    case notch(CGRect)
    case pill(CGRect)

    public var rect: CGRect {
        switch self {
        case .notch(let r), .pill(let r): return r
        }
    }

    public var isNotch: Bool {
        if case .notch = self { return true }
        return false
    }
}
