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

    /// Show in Finder, AirDrop, then Remove: the destructive verb last, at
    /// the bottom of the menu, as Clear sits at the edge of the title row.
    @Test func theTileOffersShowInFinderAirDropAndRemove() {
        let actions = ShelfView.tileActions(onRemove: {}, onAirDrop: {}, onReveal: {})
        #expect(actions.map(\.label) == ["Show in Finder", "AirDrop", "Remove"])
        #expect(actions.map(\.isDestructive) == [false, false, true])
    }

    @Test func eachActionPerformsItsOwnVerb() {
        var calls: [String] = []
        let actions = ShelfView.tileActions(
            onRemove: { calls.append("remove") },
            onAirDrop: { calls.append("airdrop") },
            onReveal: { calls.append("reveal") }
        )
        for action in actions { action.perform() }
        #expect(calls == ["reveal", "airdrop", "remove"])
    }

    /// VoiceOver reads the file's name, the same text under the tile.
    @Test func theTileIsLabelledWithTheFileName() {
        #expect(ShelfView.tileAccessibilityLabel(for: item) == "Notes.txt")
    }

    /// Show in Finder is a verb through `AppState` like Remove and AirDrop,
    /// wired at install so the view never calls `NSWorkspace` itself.
    @Test func installingWiresShowInFinder() {
        let delegate = AppDelegate()
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
