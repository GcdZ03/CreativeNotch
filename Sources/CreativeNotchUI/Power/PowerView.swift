import SwiftUI
import CreativeNotchCore

/// The power tab: four facts, and nothing that needs a timer to stay true.
///
/// Every string comes from `PowerLabel`, which the peek also reads, so the
/// panel and the notch cannot disagree about what the machine is doing.
struct PowerView: View {

    let snapshot: PowerSnapshot?

    /// The estimate `BatteryEstimateGate` is willing to stand behind.
    /// `nil` renders as "Estimating…" rather than hiding the row — see
    /// `PowerLabel.timeRemaining`.
    let estimateMinutes: Int?

    var body: some View {
        if let snapshot {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(snapshot.level)%")
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .monospacedDigit()

                    Text(PowerLabel.state(
                        source: snapshot.source,
                        isCharging: snapshot.isCharging
                    ))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
                }

                row(
                    PowerLabel.timeRemainingTitle(source: snapshot.source),
                    PowerLabel.timeRemaining(estimateMinutes)
                )

                row("Low Power Mode", snapshot.isLowPowerMode ? "On" : "Off")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        } else {
            // Reachable only for the instant between the panel opening and
            // the first IOKit read. The tab itself is hidden on machines
            // with no battery, so this is never a permanent state.
            Text("Reading power state…")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.6))
                .padding(16)
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(.white.opacity(0.6))
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .monospacedDigit()
        }
    }
}
