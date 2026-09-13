/// The SF Symbol each tab is drawn with in the header (spec §5.1).
///
/// A string, so it lives in Core and is testable for distinctness; the UI
/// turns it into an `Image(systemName:)`. `.hud` has one so the switch is
/// exhaustive without a `default` — it is never offered as a tab.
public extension Tab {
    var symbolName: String {
        switch self {
        case .shelf:     return "tray.full"
        case .clipboard: return "doc.on.clipboard"
        case .hud:       return "speaker.wave.2"
        case .power:     return "battery.100percent"
        case .timer:     return "timer"
        case .camera:    return "camera"
        }
    }
}
