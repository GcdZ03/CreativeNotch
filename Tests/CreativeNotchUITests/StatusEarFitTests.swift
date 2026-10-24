import AppKit
import SwiftUI
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// That `PanelLayout.batteryCellWidth`, which Compact's width is decided
/// from, is an upper bound on the battery cell the header actually draws
/// (2026-10-24) -- at its widest, "100%" with the charging bolt, at every
/// text size.
@MainActor
struct StatusEarFitTests {

    @Test(arguments: TextSize.allCases)
    func theBatteryCellFitsItsAllowance(size: TextSize) {
        let cell = BatteryCell(level: 100, isCharging: true)
            .environment(\.notchTextScale, size.scale)
        let view = NSHostingView(rootView: cell)
        let drawn = view.fittingSize.width
        #expect(drawn > 0)
        #expect(drawn <= NotchType.length(PanelLayout.batteryCellWidth, scale: size.scale),
                "the battery cell draws \(drawn)pt at \(size), past its allowance")
    }
}
