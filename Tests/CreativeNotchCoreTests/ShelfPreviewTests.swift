import Foundation
import Testing
@testable import CreativeNotchCore

/// Quick Look and Open on the shelf: which verbs a tile offers, in what
/// order, which items a preview walks, and how the selection moves.
///
/// All of it is pure so the rules are pinned without a window server, a
/// `QLPreviewPanel` or an app being launched.
struct ShelfPreviewTests {

    private static func item(_ name: String, pending: Bool = false) -> ShelfItem {
        ShelfItem(
            id: UUID(),
            url: URL(fileURLWithPath: "/tmp/shelf/\(name)"),
            displayName: name,
            addedAt: Date(timeIntervalSinceReferenceDate: 0),
            isPending: pending
        )
    }

    private let a = item("A.pdf")
    private let b = item("B.png")
    private let copying = item("C.mov", pending: true)
    private let d = item("D.txt")

    private var items: [ShelfItem] { [a, b, copying, d] }

    // MARK: - Verbs

    /// Open first, as in Finder's menu; Quick Look beside it; Remove last,
    /// the destructive verb at the bottom edge.
    @Test func aReadyTileOffersOpenQuickLookRevealAirDropThenRemove() {
        #expect(ShelfTileVerb.verbs(for: a) == [.open, .quickLook, .reveal, .airDrop, .remove])
    }

    /// Every verb needs the file, and a copying item has none yet.
    @Test func aPendingTileOffersNothing() {
        #expect(ShelfTileVerb.verbs(for: copying).isEmpty)
    }

    @Test func onlyRemoveIsDestructive() {
        for verb in ShelfTileVerb.allCases {
            #expect(verb.isDestructive == (verb == .remove), "\(verb)")
        }
    }

    @Test func theLabelsReadAsTheMenuDoes() {
        #expect(ShelfTileVerb.allCases.map(\.label)
            == ["Open", "Quick Look", "Show in Finder", "AirDrop", "Remove"])
    }

    /// Distinct, so the context menu and the accessibility actions can key
    /// on the label without two rows colliding.
    @Test func eachVerbHasItsOwnSymbol() {
        let symbols = ShelfTileVerb.allCases.map(\.symbolName)
        #expect(Set(symbols).count == symbols.count)
        #expect(ShelfTileVerb.quickLook.symbolName == "eye")
    }

    // MARK: - What a preview walks

    /// The preview pages through the ready items, starting at the chosen
    /// one: arrowing in Quick Look moves along the shelf, skipping a file
    /// that is still copying in.
    @Test func aPreviewWalksTheReadyItemsFromTheChosenOne() throws {
        let request = try #require(ShelfPreview.request(for: d.id, in: items))
        #expect(request.urls == [a.url, b.url, d.url])
        #expect(request.index == 2)
        #expect(request.current == d.url)
    }

    /// Space with nothing chosen previews the first file rather than
    /// nothing, the way a list with no selection starts at its top.
    @Test func withNothingChosenThePreviewStartsAtTheFirstReadyItem() throws {
        let request = try #require(ShelfPreview.request(for: nil, in: items))
        #expect(request.index == 0)
        #expect(request.current == a.url)
    }

    /// A selection left behind by an item that has since gone is no
    /// selection at all.
    @Test func aChoiceThatHasGoneStartsAtTheFirstReadyItem() throws {
        let request = try #require(ShelfPreview.request(for: UUID(), in: items))
        #expect(request.current == a.url)
    }

    /// There is no file to show yet; previewing a neighbour instead would
    /// answer a question nobody asked.
    @Test func aPendingItemIsNeverPreviewed() {
        #expect(ShelfPreview.request(for: copying.id, in: items) == nil)
    }

    @Test func aShelfWithNoReadyItemHasNothingToPreview() {
        #expect(ShelfPreview.request(for: nil, in: []) == nil)
        #expect(ShelfPreview.request(for: nil, in: [copying]) == nil)
    }

    // MARK: - Moving the selection

    @Test func rightArrowMovesToTheNextReadyItemSkippingACopyingOne() {
        #expect(ShelfSelection.moved(from: a.id, by: 1, in: items) == b.id)
        #expect(ShelfSelection.moved(from: b.id, by: 1, in: items) == d.id)
    }

    @Test func leftArrowMovesBack() {
        #expect(ShelfSelection.moved(from: d.id, by: -1, in: items) == b.id)
    }

    /// Stops at the ends, as Finder's icon view does, rather than wrapping
    /// to a tile scrolled out of sight at the other end.
    @Test func theSelectionStopsAtEitherEnd() {
        #expect(ShelfSelection.moved(from: a.id, by: -1, in: items) == a.id)
        #expect(ShelfSelection.moved(from: d.id, by: 1, in: items) == d.id)
    }

    /// The first arrow press picks a tile from the end it points away from.
    @Test func withNothingSelectedAnArrowPicksAnEnd() {
        #expect(ShelfSelection.moved(from: nil, by: 1, in: items) == a.id)
        #expect(ShelfSelection.moved(from: nil, by: -1, in: items) == d.id)
    }

    @Test func anEmptyShelfHasNothingToSelect() {
        #expect(ShelfSelection.moved(from: nil, by: 1, in: []) == nil)
        #expect(ShelfSelection.moved(from: nil, by: 1, in: [copying]) == nil)
    }

    /// Only a ready item can be selected: the selection is what Space and
    /// Open act on, and neither can act on a copy in progress.
    @Test func onlyAReadyItemIsSelectable() {
        #expect(ShelfSelection.isSelectable(a))
        #expect(!ShelfSelection.isSelectable(copying))
    }

    // MARK: - Keys

    @Test func spaceAsksForQuickLookOnTheShelfTab() {
        #expect(PanelKeyboard.action(for: .space, in: .open(.shelf), visible: Tab.allCases) == .quickLook)
    }

    @Test func theArrowsMoveTheShelfSelection() {
        #expect(PanelKeyboard.action(for: .arrowRight, in: .open(.shelf), visible: Tab.allCases)
            == .moveShelfSelection(1))
        #expect(PanelKeyboard.action(for: .arrowLeft, in: .open(.shelf), visible: Tab.allCases)
            == .moveShelfSelection(-1))
    }

    /// Off the shelf they are somebody else's: Space is typing in the
    /// timer's field, and nothing else in the panel has a selection.
    @Test func spaceAndTheArrowsPassOnOffTheShelfTab() {
        for tab in Tab.allCases where tab != .shelf {
            for key in [PanelKey.space, .arrowLeft, .arrowRight] {
                #expect(PanelKeyboard.action(for: key, in: .open(tab), visible: Tab.allCases) == nil,
                        "\(key), \(tab)")
            }
        }
    }

    @Test func spaceDoesNothingUnlessThePanelIsOpen() {
        for state in [NotchState.closed, .receiving, .peek(.dragTarget)] {
            #expect(PanelKeyboard.action(for: .space, in: state, visible: Tab.allCases) == nil)
        }
    }
}
