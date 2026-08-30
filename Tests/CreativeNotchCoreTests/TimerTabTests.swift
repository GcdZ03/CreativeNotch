import Testing
@testable import CreativeNotchCore

struct TimerTabTests {
    @Test func theTimerTabExists() {
        #expect(Tab.allCases.contains(.timer))
        #expect(Tab.timer.rawValue == "timer")
    }

    /// Tab identity is persisted as a raw string via `lastOpenTab`; changing
    /// an existing raw value would silently reopen users on a different tab.
    @Test func theExistingTabRawValuesAreUnchanged() {
        #expect(Tab.shelf.rawValue == "shelf")
        #expect(Tab.clipboard.rawValue == "clipboard")
        #expect(Tab.hud.rawValue == "hud")
    }
}
