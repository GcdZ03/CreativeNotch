import Testing
@testable import CreativeNotchCore

/// Icon tabs need a glyph per tab; a duplicate would make two tabs
/// indistinguishable, and an empty string draws nothing.
struct TabSymbolsTests {
    @Test func everyTabHasADistinctNonEmptySymbol() {
        let names = Tab.allCases.map(\.symbolName)
        #expect(names.allSatisfy { !$0.isEmpty })
        #expect(Set(names).count == names.count)
    }

    @Test func theSymbolsAreTheOnesTheSpecNames() {
        #expect(Tab.shelf.symbolName == "tray.full")
        #expect(Tab.clipboard.symbolName == "doc.on.clipboard")
        #expect(Tab.timer.symbolName == "timer")
        #expect(Tab.power.symbolName == "battery.100percent")
        #expect(Tab.camera.symbolName == "camera")
    }
}
