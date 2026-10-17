import SwiftUI
import CreativeNotchCore

/// What the notch shows for the three seconds after the power state
/// changes.
///
/// One row **below** the notch (2026-10-17): icon, the words for what
/// happened, the bar and the percentage, read left to right. It used to put
/// the icon in the left ear and the bar in the right, with the camera
/// housing between them and no words at all, so the two halves read as
/// unrelated pieces. Hanging below the housing, nothing has to be split
/// around it — the same move the music peek made.
///
/// It shows a number as well as a bar. The menu bar item people already
/// compare against has a percentage, and a bar at 19% is not actionably
/// different from a bar at 25%.
struct PowerPeekView: View {

    let event: PowerEvent

    /// The notch's own band, left empty; the row hangs below it.
    var bandHeight: CGFloat = 32

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: bandHeight)
            HStack(spacing: 8) {
                icon
                Text(PowerLabel.peekTitle(for: event))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(event.isUrgent ? tint : .white.opacity(0.95))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let percentage {
                    bar.frame(width: 56)
                    Text(percentage)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                        .monospacedDigit()
                        .rollingDigits(percentage)
                        .frame(minWidth: 30, alignment: .trailing)
                }
            }
            .padding(.horizontal, 14)
            .frame(maxHeight: .infinity)
        }
        .accessibilityElement(children: .combine)
    }

    private var icon: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 18)
    }

    private var bar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.18))
                Capsule()
                    .fill(tint)
                    .frame(width: geometry.size.width * level)
            }
        }
        .frame(height: 4)
    }

    /// The charge as a fraction, clamped — a level outside 0...1 is a bad
    /// reading, not a reason to draw outside the bar.
    var level: Double {
        switch event {
        case .pluggedIn(let level), .unplugged(let level):
            return max(0, min(1, Double(level) / 100))
        case .lowBattery(_, let level):
            return max(0, min(1, Double(level) / 100))
        case .lowPowerMode:
            return 0
        }
    }

    /// `nil` for Low Power Mode, which carries no level and must not
    /// invent one.
    var percentage: String? {
        switch event {
        case .pluggedIn(let level), .unplugged(let level):
            return "\(level)%"
        case .lowBattery(_, let level):
            return "\(level)%"
        case .lowPowerMode:
            return nil
        }
    }

    var symbol: String {
        switch event {
        case .pluggedIn:    return "battery.100.bolt"
        case .unplugged:    return "battery.50"
        case .lowBattery:   return "battery.25"
        case .lowPowerMode: return "bolt.circle"
        }
    }

    /// Low battery is the only event that earns colour.
    ///
    /// Everything else in this notch is white on black, and staying that
    /// way is what makes the exception read as urgent rather than as
    /// decoration.
    var tint: Color {
        switch event {
        case .lowBattery: return .yellow
        default:          return .white.opacity(0.9)
        }
    }
}

private extension PowerEvent {
    var isUrgent: Bool {
        if case .lowBattery = self { return true }
        return false
    }
}
