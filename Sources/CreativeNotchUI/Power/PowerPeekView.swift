import SwiftUI
import CreativeNotchCore

/// What the notch shows for the three seconds after the power state
/// changes.
///
/// Shaped after `HUDView`, not after `NowPlayingBadgeView`. The badge is
/// the *closed-notch* ambient tab and this module ships no persistent
/// badge; the peek slot's existing occupants are `HUDView` and
/// `NowPlayingPeekView`, and both split around `notchGap` because on a
/// notched Mac the middle of this band is the camera housing. `HUDView` is
/// an icon plus a level bar, which is exactly what a battery indicator is.
///
/// The one thing this adds over `HUDView` is a number. `HUDView`
/// deliberately shows none, because Apple's volume HUD shows none and
/// matching it makes the notch read as familiar. Battery is the opposite
/// case: the menu bar item people already compare against has a
/// percentage, and a bar at 19% is not actionably different from a bar at
/// 25%.
struct PowerPeekView: View {

    let event: PowerEvent

    /// Width of the physical notch to leave empty down the middle. Zero on
    /// a notchless Mac, where there is no camera housing to avoid.
    var notchGap: CGFloat = 0

    var body: some View {
        if notchGap > 0 {
            // Icon in the left ear, level in the right, nothing behind the
            // notch. Both ears take an equal share of what is left, so the
            // layout follows the real notch width on whatever Mac it is.
            HStack(spacing: 0) {
                icon
                    .frame(maxWidth: .infinity)

                Color.clear
                    .frame(width: notchGap)

                trailing
                    .padding(.trailing, 16)
                    .frame(maxWidth: .infinity)
            }
        } else {
            HStack(spacing: 10) {
                icon
                trailing
            }
            .padding(.horizontal, 22)
        }
    }

    private var icon: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 18)
    }

    @ViewBuilder
    private var trailing: some View {
        if let percentage {
            HStack(spacing: 8) {
                bar
                Text(percentage)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                    .monospacedDigit()
            }
        } else {
            Text(caption)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
        }
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

    /// Words, for the one event that has no number to show.
    var caption: String {
        switch event {
        case .lowPowerMode(let enabled):
            return enabled ? "Low Power Mode" : "Low Power Mode off"
        default:
            return ""
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
