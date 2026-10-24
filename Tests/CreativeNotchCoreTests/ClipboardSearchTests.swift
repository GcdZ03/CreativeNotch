import Foundation
import Testing
@testable import CreativeNotchCore

/// Searching the clipboard history: what a query matches, and that the
/// filter never reorders what it keeps.
struct ClipboardSearchTests {

    private func entry(_ content: ClipboardContent, pinned: Bool = false) -> ClipboardEntry {
        ClipboardEntry(id: UUID(), content: content, addedAt: Date(timeIntervalSince1970: 0),
                       isPinned: pinned)
    }

    @Test func anEmptyQueryMatchesEverything() {
        let entries = [entry(.text("one")), entry(.text("two"))]
        #expect(ClipboardSearch.filter(entries, query: "") == entries)
    }

    /// A stray space in the field is not a search: filtering everything out
    /// because the person pressed the space bar would read as a lost history.
    @Test func aBlankQueryIsNotASearch() {
        let entries = [entry(.text("one"))]
        #expect(ClipboardSearch.filter(entries, query: "   \n") == entries)
        #expect(!ClipboardSearch.isActive("  "))
        #expect(ClipboardSearch.isActive(" a "))
    }

    @Test func matchingIgnoresCase() {
        #expect(ClipboardSearch.matches(.text("Hello World"), query: "hello"))
        #expect(ClipboardSearch.matches(.text("hello world"), query: "WORLD"))
    }

    /// "cafe" finds "Café", and the other way round: typing the accent is
    /// optional on a keyboard that makes it a dead-key chord.
    @Test func matchingIgnoresDiacritics() {
        #expect(ClipboardSearch.matches(.text("Meet at the Café"), query: "cafe"))
        #expect(ClipboardSearch.matches(.text("naive"), query: "naïve"))
    }

    @Test func aMissIsAMiss() {
        #expect(!ClipboardSearch.matches(.text("Hello"), query: "bye"))
    }

    /// Each word must appear, in any order — so "invoice march" finds
    /// "March invoice #42" as a person would expect.
    @Test func everyWordMustAppearInAnyOrder() {
        #expect(ClipboardSearch.matches(.text("March invoice #42"), query: "invoice march"))
        #expect(!ClipboardSearch.matches(.text("March invoice #42"), query: "invoice april"))
    }

    /// An image has no text, so it answers to what its row says: "PNG image".
    @Test func anImageMatchesByWhatItsRowSays() {
        let png = ClipboardContent.image(Data([1, 2, 3]), ext: "png")
        #expect(ClipboardSearch.matches(png, query: "image"))
        #expect(ClipboardSearch.matches(png, query: "png"))
        #expect(!ClipboardSearch.matches(png, query: "jpeg"))
    }

    /// The text searched is the whole entry, not the truncated preview: a
    /// word past the eightieth character is still found.
    @Test func theWholeTextIsSearchedNotThePreview() {
        let long = String(repeating: "x ", count: 100) + "needle"
        #expect(ClipboardSearch.matches(.text(long), query: "needle"))
    }

    @Test func filteringKeepsTheOrderItWasGiven() {
        let a = entry(.text("apple pie"), pinned: true)
        let b = entry(.text("banana"))
        let c = entry(.text("apple juice"))
        #expect(ClipboardSearch.filter([a, b, c], query: "apple") == [a, c])
    }
}
