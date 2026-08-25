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

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 18)

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
        .padding(.horizontal, 22)
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
