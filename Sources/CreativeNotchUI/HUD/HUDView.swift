import SwiftUI
import CreativeNotchCore

/// An icon and a level bar — the same information Apple's HUD conveys, in
/// the place your eyes already go.
///
/// Deliberately no percentage and no device name: matching what Apple
/// conveys makes the notch read as familiar rather than as a second,
/// different indicator.
struct HUDView: View {
    let kind: HUDKind

    /// Width of the physical notch to leave empty down the middle.
    ///
    /// Zero on a notchless Mac, where there is no camera housing to avoid
    /// and the icon and bar can simply sit next to each other.
    var notchGap: CGFloat = 0

    var body: some View {
        if notchGap > 0 {
            // Icon in the left ear, bar in the right, nothing behind the
            // notch. Both ears take an equal share of what is left, so the
            // layout follows the real notch width on whatever Mac it is.
            HStack(spacing: 0) {
                icon
                    .frame(maxWidth: .infinity)

                Color.clear
                    .frame(width: notchGap)

                bar
                    .padding(.trailing, 16)
                    .frame(maxWidth: .infinity)
            }
        } else {
            HStack(spacing: 10) {
                icon
                bar
            }
            .padding(.horizontal, 22)
        }
    }

    private var icon: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white.opacity(0.9))
            .frame(width: 18)
    }

    private var bar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.18))
                Capsule()
                    .fill(.white.opacity(0.9))
                    .frame(width: geometry.size.width * level)
            }
        }
        .frame(height: 4)
    }

    private var level: Double {
        switch kind {
        case .volume(let value):     return max(0, min(1, value))
        case .brightness(let value): return max(0, min(1, value))
        case .mute(let muted):       return muted ? 0 : 1
        }
    }

    private var symbol: String {
        switch kind {
        case .mute(let muted):
            return muted ? "speaker.slash.fill" : "speaker.wave.2.fill"
        case .brightness:
            return "sun.max.fill"
        case .volume(let value):
            if value <= 0    { return "speaker.fill" }
            if value < 0.34  { return "speaker.wave.1.fill" }
            if value < 0.67  { return "speaker.wave.2.fill" }
            return "speaker.wave.3.fill"
        }
    }
}
