import Testing
@testable import CreativeNotchCore

/// Whether the notch's display is showing a full-screen app (2026-10-17).
///
/// Since the notch moved into a Space of its own (#34), it no longer hid over
/// full-screen apps by itself. The window server's per-display Space list says
/// which Space is current and what kind it is. Shapes below are modelled on a
/// real reading, taken with a window full-screen: desktops reported type 0,
/// the full-screen Space type 4.
struct FullScreenSpacesTests {

    private let uuid = "37D8832A-2D66-02CA-B9F7-8F30A301B230"

    private func display(_ id: String, currentType: Int) -> [String: Any] {
        [
            "Display Identifier": id,
            "Current Space": ["ManagedSpaceID": 608, "type": currentType],
            "Spaces": [["ManagedSpaceID": 1, "type": 0], ["ManagedSpaceID": 608, "type": currentType]],
        ]
    }

    @Test func aFullScreenCurrentSpaceIsFullScreen() {
        #expect(FullScreenSpaces.isFullScreen(displays: [display(uuid, currentType: 4)], displayUUID: uuid))
    }

    @Test func aDesktopIsNot() {
        #expect(!FullScreenSpaces.isFullScreen(displays: [display(uuid, currentType: 0)], displayUUID: uuid))
    }

    /// Only the notch's own display counts: a film full-screen on an
    /// external monitor must not hide the notch on the laptop.
    @Test func anotherDisplaysFullScreenDoesNotCount() {
        let displays = [display(uuid, currentType: 0), display("OTHER", currentType: 4)]
        #expect(!FullScreenSpaces.isFullScreen(displays: displays, displayUUID: uuid))
    }

    /// With "Displays have separate Spaces" off, there is one entry named
    /// "Main" for every display.
    @Test func aSharedMainEntryApplies() {
        #expect(FullScreenSpaces.isFullScreen(displays: [display("Main", currentType: 4)], displayUUID: uuid))
    }

    /// Anything unreadable leaves the notch showing: hiding it by mistake is
    /// worse than failing to hide it.
    @Test func anythingUnreadableIsNotFullScreen() {
        #expect(!FullScreenSpaces.isFullScreen(displays: [], displayUUID: uuid))
        #expect(!FullScreenSpaces.isFullScreen(displays: [["Display Identifier": uuid]], displayUUID: uuid))
        #expect(!FullScreenSpaces.isFullScreen(
            displays: [["Display Identifier": uuid, "Current Space": ["type": "4"]]], displayUUID: uuid
        ))
        #expect(!FullScreenSpaces.isFullScreen(displays: [display(uuid, currentType: 4)], displayUUID: nil))
    }
}
