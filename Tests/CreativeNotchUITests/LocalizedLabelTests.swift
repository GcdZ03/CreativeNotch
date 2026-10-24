import Foundation
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// Labels that the localization pass reworded or reformatted (2026-10-24),
/// pinned so the English stays what was intended.
struct LocalizedLabelTests {

    /// Same text as the old `String(format: "%.1f s")` in a point-decimal
    /// region; the region's own separator elsewhere.
    @Test func hoverDelayReadsLikeBeforeInAPointDecimalRegion() {
        let us = Locale(identifier: "en_US")
        #expect(HoverRow.delayLabel(0.5, locale: us) == "0.5 s")
        #expect(HoverRow.delayLabel(0, locale: us) == "0.0 s")
        #expect(HoverRow.delayLabel(2, locale: us) == "2.0 s")
    }

    @Test func hoverDelayUsesTheRegionsDecimalSeparator() {
        #expect(HoverRow.delayLabel(0.5, locale: Locale(identifier: "de_DE")) == "0,5 s")
    }

    /// Only "None" is this app's word; the sounds keep macOS's names, which
    /// are also what `NSSound(named:)` is handed.
    @Test func chimeTitles() {
        #expect(LimitsRows.title(for: .none) == "None")
        for chime in ChimeSound.allCases where chime != .none {
            #expect(LimitsRows.title(for: chime) == chime.rawValue)
        }
    }

    @Test func titleRowLabels() {
        #expect(NotchRootView.label(for: .closed) == "")
        #expect(NotchRootView.label(for: .peek(.dragTarget)) == "CreativeNotch")
        #expect(NotchRootView.label(for: .receiving) == "Drop here")
        #expect(NotchRootView.label(for: .open(.power)) == "Battery")
        for tab in Tab.allCases {
            #expect(NotchRootView.label(for: .open(tab)) == tab.title)
        }
    }
}
