/// The SF Symbol each tab is drawn with in the header (spec §5.1).
///
/// A string, so it lives in Core and is testable for distinctness; the UI
/// turns it into an `Image(systemName:)`.
public extension Tab {
    var symbolName: String {
        switch self {
        case .shelf:     return "tray.full"
        case .clipboard: return "doc.on.clipboard"
        case .power:     return "battery.100percent"
        case .timer:     return "timer"
        case .camera:    return "camera"
        }
    }
}
