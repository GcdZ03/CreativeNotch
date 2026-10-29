import AppKit
import QuartzCore
import SwiftUI
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// The bars' motion (2026-10-29): handed to Core Animation once, capped,
/// and in the closed notch only when asked for.
///
/// What it costs is measured, not asserted here: see
/// `docs/research/2026-10-29-equalizer-cost.md`. These pin the shape that
/// measurement depends on -- a repeating layer animation the app never
/// touches again, at a capped frame rate.
@MainActor
struct EqualizerMotionTests {

    // MARK: - The animation

    @Test func eachBarHasOneRepeatingSwingOfItsHeight() {
        let view = BarsLayerView(color: .white)
        let swings = view.swings
        #expect(swings.count == 4)
        for (i, swing) in swings.enumerated() {
            #expect(swing.keyPath == "bounds.size.height")
            #expect(swing.repeatCount == .infinity)
            #expect(swing.autoreverses)
            #expect(swing.fromValue as? CGFloat == EqualizerBarsView.height * EqualizerBarsView.low[i])
            #expect(swing.toValue as? CGFloat == EqualizerBarsView.height * EqualizerBarsView.high[i])
        }
        // Out of step, so the four never pulse together.
        #expect(Set(swings.map(\.duration)).count == 4)
    }

    /// The window server composites every frame it is asked for. Uncapped,
    /// a ProMotion display asks for up to 120 a second.
    @Test func theFrameRateIsCapped() {
        for swing in BarsLayerView(color: .white).swings {
            #expect(swing.preferredFrameRateRange.maximum == EqualizerBarsView.framesPerSecond)
            #expect(swing.preferredFrameRateRange.preferred == EqualizerBarsView.framesPerSecond)
        }
        #expect(EqualizerBarsView.framesPerSecond <= 30)
    }

    /// A new tint recolours the bars without restarting their animations.
    @Test func recolouringKeepsTheSwings() {
        let view = BarsLayerView(color: .white)
        let before = view.swings.map(ObjectIdentifier.init)
        view.setColor(.systemPink)
        #expect(view.swings.map(ObjectIdentifier.init) == before)
    }

    // MARK: - When the closed notch's bars move

    private func state(moving: Bool, lowPower: Bool? = nil) -> AppState {
        let s = AppState()
        s.layoutOptions = LayoutOptions(animatesNowPlayingBars: moving)
        if let lowPower {
            s.power = PowerSnapshot(level: 50, source: .battery, isCharging: false, isLowPowerMode: lowPower)
        }
        return s
    }

    @Test func stillUnlessAskedFor() {
        #expect(NotchRootView.closedBarsMove(for: AppState()) == false)
        #expect(NotchRootView.closedBarsMove(for: state(moving: false)) == false)
        #expect(NotchRootView.closedBarsMove(for: state(moving: true)) == true)
    }

    @Test func lowPowerModeStillsThem() {
        #expect(NotchRootView.closedBarsMove(for: state(moving: true, lowPower: true)) == false)
        #expect(NotchRootView.closedBarsMove(for: state(moving: true, lowPower: false)) == true)
    }
}
