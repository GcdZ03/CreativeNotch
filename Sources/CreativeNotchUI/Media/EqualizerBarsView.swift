import SwiftUI

/// Four bars that say "music is playing" (spec 2026-10-15).
///
/// **Static unless asked to animate.** In the closed notch they stand
/// still: the badge is on screen for as long as music plays, and this app
/// exists to not redraw continuously for that long. They move only in the
/// music peek, which is on screen for as long as the cursor is.
///
/// The motion is a repeating SwiftUI animation started on appear, not a
/// `TimelineView`. A render that has to be repeatable — the rendering
/// tests compare two — turns it off with `animatesEqualizer`, which pins
/// the bars to their first frame.
struct EqualizerBarsView: View {
    var isPlaying: Bool
    var animates: Bool
    var color: Color = .white

    /// The still silhouette: uneven, so it reads as bars rather than a
    /// block.
    static let rest: [CGFloat] = [0.45, 0.85, 0.6, 1.0]
    /// Paused: flat and short, but still there, so the layout holds.
    static let paused: CGFloat = 0.22

    static let height: CGFloat = 14

    @Environment(\.animatesEqualizer) private var motionAllowed

    var body: some View {
        let moving = animates && motionAllowed
        HStack(spacing: 2) {
            ForEach(0..<Self.rest.count, id: \.self) { i in
                Bar(index: i, isPlaying: isPlaying, animates: moving, color: color)
            }
        }
        .frame(height: Self.height)
        // A new identity when the motion stops, because a repeating
        // animation cannot be cancelled by setting a value back.
        .id(isPlaying && moving)
        .accessibilityHidden(true)
    }

    private struct Bar: View {
        let index: Int
        let isPlaying: Bool
        let animates: Bool
        let color: Color

        @State private var up = false

        private static let low: [CGFloat] = [0.3, 0.45, 0.25, 0.4]
        private static let high: [CGFloat] = [0.9, 1.0, 0.8, 0.95]
        private static let period: [Double] = [0.42, 0.33, 0.5, 0.38]

        var body: some View {
            Capsule()
                .fill(color)
                .frame(width: 3, height: EqualizerBarsView.height * fraction)
                .onAppear {
                    guard isPlaying, animates else { return }
                    withAnimation(.easeInOut(duration: Self.period[index]).repeatForever(autoreverses: true)) {
                        up = true
                    }
                }
        }

        private var fraction: CGFloat {
            guard isPlaying else { return EqualizerBarsView.paused }
            guard animates else { return EqualizerBarsView.rest[index] }
            return up ? Self.high[index] : Self.low[index]
        }
    }
}

extension EnvironmentValues {
    /// Whether `EqualizerBarsView` may move at all. On everywhere in the
    /// app; off where a render must be identical from one run to the next.
    @Entry var animatesEqualizer: Bool = true
}
