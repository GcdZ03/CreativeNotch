import AppKit
import QuartzCore
import SwiftUI

/// Four bars that say "music is playing" (spec 2026-10-15; motion
/// 2026-10-29).
///
/// **Still unless asked to move.** In the closed notch they stand still by
/// default: the badge is on screen for as long as music plays, and this app
/// exists to not redraw continuously for that long. They move in the music
/// peek, which is on screen for as long as the cursor is, and in the closed
/// notch only when Settings → Layout → "Moving bars" is on.
///
/// **The motion belongs to Core Animation, not to SwiftUI.** A repeating
/// SwiftUI animation re-evaluates the view in this process on every frame:
/// measured on 2026-10-29, four bars cost the app 5–6% of a core while they
/// moved. The same four bars as `CABasicAnimation`s cost it 0.01% -- the
/// animation is handed to the window server once and runs there, so the app
/// does no work per frame at all. It is capped at `framesPerSecond` because
/// the window server still composites every frame it is asked for, and on a
/// ProMotion display an uncapped animation is asked for up to 120 (see
/// `docs/research/2026-10-29-equalizer-cost.md`).
///
/// A render that has to be repeatable -- the rendering tests compare two --
/// turns motion off with `animatesEqualizer`, which draws the still bars in
/// SwiftUI; `ImageRenderer` cannot draw an AppKit layer anyway.
struct EqualizerBarsView: View {
    var isPlaying: Bool
    var animates: Bool
    var color: Color = .white

    /// The still silhouette: uneven, so it reads as bars rather than a
    /// block.
    static let rest: [CGFloat] = [0.45, 0.85, 0.6, 1.0]
    /// Paused: flat and short, but still there, so the layout holds.
    static let paused: CGFloat = 0.22
    /// Each bar's swing and period: out of step, so the four never pulse
    /// together.
    static let low: [CGFloat] = [0.3, 0.45, 0.25, 0.4]
    static let high: [CGFloat] = [0.9, 1.0, 0.8, 0.95]
    static let period: [Double] = [0.42, 0.33, 0.5, 0.38]

    static let height: CGFloat = 14
    static let barWidth: CGFloat = 3
    static let spacing: CGFloat = 2
    static var width: CGFloat { barWidth * 4 + spacing * 3 }

    /// Smooth enough for bars this size, and a sixth of what an uncapped
    /// animation asks a ProMotion display for.
    static let framesPerSecond: Float = 20

    @Environment(\.animatesEqualizer) private var motionAllowed

    var body: some View {
        if isPlaying && animates && motionAllowed {
            MovingBars(color: NSColor(color))
                .frame(width: Self.width, height: Self.height)
                .accessibilityHidden(true)
        } else {
            HStack(spacing: Self.spacing) {
                ForEach(0..<Self.rest.count, id: \.self) { i in
                    Capsule()
                        .fill(color)
                        .frame(width: Self.barWidth, height: Self.height * (isPlaying ? Self.rest[i] : Self.paused))
                }
            }
            .frame(height: Self.height)
            .accessibilityHidden(true)
        }
    }
}

/// The moving bars: four layers, each with one repeating animation of its
/// height, added once when the view is made and never touched again. The
/// window server plays them; removing the view removes them.
private struct MovingBars: NSViewRepresentable {
    let color: NSColor

    func makeNSView(context: Context) -> BarsLayerView {
        BarsLayerView(color: color)
    }

    func updateNSView(_ view: BarsLayerView, context: Context) {
        view.setColor(color)
    }
}

final class BarsLayerView: NSView {
    private var bars: [CALayer] = []

    init(color: NSColor) {
        super.init(frame: CGRect(x: 0, y: 0, width: EqualizerBarsView.width, height: EqualizerBarsView.height))
        wantsLayer = true
        for i in 0..<4 {
            let bar = CALayer()
            bar.cornerRadius = EqualizerBarsView.barWidth / 2
            bar.backgroundColor = color.cgColor
            bar.add(Self.swing(i), forKey: "swing")
            layer?.addSublayer(bar)
            bars.append(bar)
        }
        layoutBars()
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        layoutBars()
    }

    func setColor(_ color: NSColor) {
        for bar in bars { bar.backgroundColor = color.cgColor }
    }

    /// The animations read in the layers' own key paths, so laying out again
    /// moves the bars without restarting them.
    private func layoutBars() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, bar) in bars.enumerated() {
            let x = CGFloat(i) * (EqualizerBarsView.barWidth + EqualizerBarsView.spacing)
            bar.bounds = CGRect(x: 0, y: 0, width: EqualizerBarsView.barWidth,
                                height: EqualizerBarsView.height * EqualizerBarsView.rest[i])
            bar.position = CGPoint(x: x + EqualizerBarsView.barWidth / 2, y: bounds.midY)
        }
        CATransaction.commit()
    }

    /// One bar's height, between its low and high, out and back for ever.
    /// The height rather than a vertical scale, so the rounded ends stay
    /// round at every point of the swing.
    static func swing(_ i: Int) -> CABasicAnimation {
        let swing = CABasicAnimation(keyPath: "bounds.size.height")
        swing.fromValue = EqualizerBarsView.height * EqualizerBarsView.low[i]
        swing.toValue = EqualizerBarsView.height * EqualizerBarsView.high[i]
        swing.duration = EqualizerBarsView.period[i]
        swing.autoreverses = true
        swing.repeatCount = .infinity
        swing.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        swing.isRemovedOnCompletion = false
        let fps = EqualizerBarsView.framesPerSecond
        swing.preferredFrameRateRange = CAFrameRateRange(minimum: fps / 2, maximum: fps, preferred: fps)
        return swing
    }

    /// For tests: the animations the window server is playing.
    var swings: [CABasicAnimation] {
        bars.compactMap { $0.animation(forKey: "swing") as? CABasicAnimation }
    }
}

extension EnvironmentValues {
    /// Whether `EqualizerBarsView` may move at all. On everywhere in the
    /// app; off where a render must be identical from one run to the next.
    @Entry var animatesEqualizer: Bool = true
}
