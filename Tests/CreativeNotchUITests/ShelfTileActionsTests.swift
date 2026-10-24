import AppKit
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// A shelf tile's verbs, reachable without hovering.
///
/// The × and AirDrop buttons exist only while the pointer is over a tile,
/// so VoiceOver and keyboard users never met them. The same verbs now back
/// the tile's accessibility actions and its context menu; what is tested
/// is the list both are built from, since neither is reachable from a
/// unit test once SwiftUI has rendered it.
@MainActor
struct ShelfTileActionsTests {

    private let item = ShelfItem(
        id: UUID(),
        url: URL(fileURLWithPath: "/tmp/shelf/Notes.txt"),
        displayName: "Notes.txt",
        addedAt: Date()
    )

    /// Open and Quick Look first, as Finder's menu has them; then Show in
    /// Finder and AirDrop; Remove last, at the bottom of the menu, as Clear
    /// sits at the edge of the title row. The order itself is Core's
    /// (`ShelfTileVerb`); this checks the view builds its menu from it.
    @Test func theTileOffersOpenQuickLookShowInFinderAirDropAndRemove() {
        let actions = ShelfView.tileActions(for: item) { _ in }
        #expect(actions.map(\.label) == ["Open", "Quick Look", "Show in Finder", "AirDrop", "Remove"])
        #expect(actions.map(\.isDestructive) == [false, false, false, false, true])
    }

    @Test func eachActionPerformsItsOwnVerb() {
        var calls: [ShelfTileVerb] = []
        let actions = ShelfView.tileActions(for: item) { calls.append($0) }
        for action in actions { action.perform() }
        #expect(calls == [.open, .quickLook, .reveal, .airDrop, .remove])
    }

    /// VoiceOver reads the file's name, the same text under the tile.
    @Test func theTileIsLabelledWithTheFileName() {
        #expect(ShelfView.tileAccessibilityLabel(for: item) == "Notes.txt")
    }

    /// Show in Finder is a verb through `AppState` like Remove and AirDrop,
    /// wired at install so the view never calls `NSWorkspace` itself.
    @Test func installingWiresShowInFinder() {
        let delegate = AppDelegate()
        delegate.shelfTrash = TestTrash.shelf
        delegate.preferencesDefaults = TestDefaults.isolated("shelf-tile-actions")
        delegate.growthDelay = .zero
        delegate.shelfDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CreativeNotchTileActions-\(UUID().uuidString)")
        delegate.install(metrics: ScreenMetrics(
            frame: CGRect(x: 1470, y: 200, width: 1470, height: 956),
            safeAreaTopInset: 38,
            auxiliaryTopLeftWidth: 620,
            auxiliaryTopRightWidth: 620,
            menuBarHeight: 38
        ))
        #expect(delegate.state.onRevealShelfItem != nil)
    }
}
