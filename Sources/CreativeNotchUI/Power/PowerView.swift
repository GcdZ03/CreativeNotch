import SwiftUI
import CreativeNotchCore

/// The battery tab: a gauge, the level, what the machine is doing, and
/// whether Low Power Mode is on (spec §5.8).
///
/// It showed a time-remaining estimate too, and no longer does. That row
/// was the module's whole difficulty — a settling window, an agreement
/// rule, a quantisation floor — and both of the bugs found by actually
/// running the app were in it. What is left needs no gate, no clock and no
/// calibration: every value here is a fact IOKit states outright.
///
/// Every string comes from `PowerLabel`, which the peek also reads, so the
/// panel and the notch cannot disagree about what the machine is doing. The
/// one colour comes from `PowerGaugeTone`, so the gauge and the header's
/// battery cell cannot disagree about what "low" is.
struct PowerView: View {

    let snapshot: PowerSnapshot?
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    /// The glyph centred on the gauge, so its state is not carried by the
    /// fill's colour alone. The same Core rule as the header's cell, so the
    /// two cannot disagree about whether a low battery is marked.
    static func glyph(for snapshot: PowerSnapshot, differentiateWithoutColor: Bool) -> String? {
        PowerGaugeTone.tone(level: snapshot.level, isCharging: snapshot.isCharging)
            .glyph(differentiateWithoutColor: differentiateWithoutColor)
    }

    /// The gauge's fill, from Core's rule. Static so the mapping is testable
    /// without rendering.
    static func fill(for snapshot: PowerSnapshot) -> Color {
        switch PowerGaugeTone.tone(level: snapshot.level, isCharging: snapshot.isCharging) {
        case .normal:   return .white
        case .low:      return .yellow
        case .charging: return .green
        }
    }

    var body: some View {
        if let snapshot {
            HStack(spacing: 20) {
                gauge(snapshot)

                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(String(localized: "\(snapshot.level)%", bundle: .creativeNotch, comment: "Battery level"))
                            .notchFont(34, weight: .semibold, design: .rounded)
                            .monospacedDigit()
                            .rollingDigits(snapshot.level)
                            .foregroundStyle(.white)

                        Text(PowerLabel.state(
                            source: snapshot.source,
                            isCharging: snapshot.isCharging,
                            isCharged: snapshot.isCharged
                        ))
                        .notchFont(14, weight: .medium, design: .rounded)
                        .foregroundStyle(.ink(0.55))
                    }

                    HStack(spacing: 8) {
                        Text("Low Power Mode", bundle: .creativeNotch)
                            .notchFont(12, weight: .medium, design: .rounded)
                            .foregroundStyle(.ink(0.6))
                        Text(snapshot.isLowPowerMode
                             ? String(localized: "On", bundle: .creativeNotch, comment: "Low Power Mode is on")
                             : String(localized: "Off", bundle: .creativeNotch, comment: "Low Power Mode is off"))
                            .notchFont(10, weight: .semibold, design: .rounded)
                            .foregroundStyle(.ink(0.85))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(.hairline(0.10)))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.leading, 6)
            .padding(.bottom, 10)
        } else {
            // Reachable only for the instant between the panel opening and
            // the first IOKit read. The tab itself is hidden on machines
            // with no battery, so this is never a permanent state.
            Text("Reading power state…", bundle: .creativeNotch)
                .notchFont(12, weight: .medium, design: .rounded)
                .foregroundStyle(.ink(0.6))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// An 88×44 cell: outline, terminal nub, fill proportional to level,
    /// and the state glyph centred on it.
    ///
    /// The glyph is white with a dark halo because it can land on either a
    /// green or yellow fill or the black inside an emptier cell, and must
    /// read on all three.
    private func gauge(_ s: PowerSnapshot) -> some View {
        let level = CGFloat(min(100, max(0, s.level))) / 100
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.ink(0.6), lineWidth: 2.5)
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Self.fill(for: s))
                .frame(width: max(6, (88 - 12) * level))
                .padding(6)
        }
        .frame(width: 88, height: 44)
        .overlay {
            if let glyph = Self.glyph(for: s, differentiateWithoutColor: differentiateWithoutColor) {
                Image(systemName: glyph)
                    .notchFont(18, weight: .bold)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 1.5)
            }
        }
        .overlay(alignment: .trailing) {
            RoundedRectangle(cornerRadius: 2)
                .fill(.ink(0.6))
                .frame(width: 5, height: 16)
                .offset(x: 8)
        }
        .padding(.trailing, 8)
        .accessibilityHidden(true)
    }
}
