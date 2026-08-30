import Foundation
import SwiftUI
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// What the peek is built with, read without rendering.
@MainActor
struct PowerViewTests {

    private func app(notch: Bool) -> AppState {
        let state = AppState()
        let rect = CGRect(x: 100, y: 0, width: 200, height: 32)
        state.setGeometry(
            anchor: notch ? .notch(rect) : .pill(rect),
            panelFrame: CGRect(x: 0, y: 0, width: 400, height: 200)
        )
        return state
    }

    // MARK: - The notch gap

    /// The gap argument is *supplied*, not merely honoured.
    ///
    /// `PeekRenderingTests` proves the peek views honour `notchGap`;
    /// nothing proved `NotchRootView` supplies the right one, and
    /// replacing the argument with `0` once left the whole suite green for
    /// the now-playing peek. Reading the argument without rendering is the
    /// same fix that was applied there.
    @Test func theNotchGapIsSuppliedFromTheAnchor() {
        let peek = NotchRootView.powerPeek(
            for: app(notch: true), event: .unplugged(level: 66)
        )

        #expect(peek.notchGap == 200)
    }

    /// Zero on a pill Mac and on external displays, where the middle of
    /// the band is ordinary screen.
    @Test func aPillMacGetsNoGap() {
        let peek = NotchRootView.powerPeek(
            for: app(notch: false), event: .unplugged(level: 66)
        )

        #expect(peek.notchGap == 0)
    }

    /// The event reaches the view unchanged. A peek that draws the right
    /// shape for the wrong event is the failure a gap assertion misses.
    @Test func theEventIsSuppliedUnchanged() {
        let peek = NotchRootView.powerPeek(
            for: app(notch: true), event: .lowBattery(threshold: 10, level: 9)
        )

        #expect(peek.event == .lowBattery(threshold: 10, level: 9))
    }

    // MARK: - What it shows

    /// Unlike `HUDView`, which deliberately shows no number because
    /// Apple's volume HUD shows none, the battery peek shows a percentage:
    /// the menu bar item people compare it against has one, and a bar at
    /// 19% is not actionably different from a bar at 25%.
    @Test func theLevelIsShownAsAPercentage() {
        #expect(PowerPeekView(event: .unplugged(level: 66)).percentage == "66%")
        #expect(PowerPeekView(event: .pluggedIn(level: 66)).percentage == "66%")
        #expect(PowerPeekView(event: .lowBattery(threshold: 20, level: 19))
            .percentage == "19%")
    }

    /// Low Power Mode carries no level, so it shows none rather than
    /// inventing one — and says something instead.
    @Test func lowPowerModeShowsWordsRatherThanAPercentage() {
        let on = PowerPeekView(event: .lowPowerMode(enabled: true))
        let off = PowerPeekView(event: .lowPowerMode(enabled: false))

        #expect(on.percentage == nil)
        #expect(on.caption == "Low Power Mode")
        #expect(off.caption != on.caption)
        #expect(off.caption.isEmpty == false)
    }

    @Test func theBarFollowsTheLevel() {
        #expect(PowerPeekView(event: .unplugged(level: 50)).level == 0.5)
        #expect(PowerPeekView(event: .lowBattery(threshold: 10, level: 9)).level == 0.09)
    }

    /// A level outside 0...100 is a bad reading, not a reason to draw
    /// outside the bar.
    @Test func theBarIsClampedAgainstNonsense() {
        #expect(PowerPeekView(event: .unplugged(level: 150)).level == 1)
        #expect(PowerPeekView(event: .unplugged(level: -20)).level == 0)
    }

    /// Four events, four glyphs. Two events sharing one is a peek that
    /// cannot be told apart from another at a glance, which is the only
    /// thing a peek is for.
    @Test func eachEventHasItsOwnGlyph() {
        let symbols = [
            PowerPeekView(event: .pluggedIn(level: 66)).symbol,
            PowerPeekView(event: .unplugged(level: 66)).symbol,
            PowerPeekView(event: .lowBattery(threshold: 20, level: 19)).symbol,
            PowerPeekView(event: .lowPowerMode(enabled: true)).symbol,
        ]

        #expect(Set(symbols).count == symbols.count)
    }

    /// Every glyph resolves. A misspelled SF Symbol name draws nothing at
    /// all and looks identical to a peek that never fired.
    @Test func everyGlyphIsARealSymbol() {
        for event: PowerEvent in [
            .pluggedIn(level: 66),
            .unplugged(level: 66),
            .lowBattery(threshold: 20, level: 19),
            .lowPowerMode(enabled: true),
        ] {
            let symbol = PowerPeekView(event: event).symbol
            #expect(
                NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil,
                "\(symbol) is not a system symbol"
            )
        }
    }

    /// Low battery is the only event that earns colour. Everything else in
    /// this notch is white on black, and staying that way is what makes
    /// the exception read as urgent rather than as decoration.
    @Test func onlyLowBatteryIsTinted() {
        #expect(PowerPeekView(event: .lowBattery(threshold: 20, level: 19)).tint == .yellow)
        #expect(PowerPeekView(event: .unplugged(level: 66)).tint != .yellow)
        #expect(PowerPeekView(event: .pluggedIn(level: 66)).tint != .yellow)
        #expect(PowerPeekView(event: .lowPowerMode(enabled: true)).tint != .yellow)
    }
}
