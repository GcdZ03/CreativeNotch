import Foundation
import Testing
@testable import CreativeNotchCore

/// Which copies the clipboard ring refuses because of the app they came from.
struct ClipboardExclusionsTests {

    private let excluded = ["com.agilebits.onepassword7", "com.apple.Terminal"]

    @Test func anEmptyListExcludesNothing() {
        #expect(ClipboardExclusions.excludes(source: "com.apple.Terminal", frontmost: "com.apple.Terminal", excluded: []) == false)
    }

    @Test func theFrontmostAppIsMatched() {
        #expect(ClipboardExclusions.excludes(source: nil, frontmost: "com.apple.Terminal", excluded: excluded))
        #expect(ClipboardExclusions.excludes(source: nil, frontmost: "com.apple.Safari", excluded: excluded) == false)
    }

    /// `org.nspasteboard.source` is the copying app's own word, and the only
    /// answer when the copy came from something that is not frontmost -- a
    /// menu bar password manager, a background helper.
    @Test func theDeclaredSourceIsMatched() {
        #expect(ClipboardExclusions.excludes(source: "com.agilebits.onepassword7", frontmost: "com.apple.Safari", excluded: excluded))
    }

    /// Either one is enough. The list is a privacy promise, and a missed
    /// entry costs only a copy that is not in the history.
    @Test func eitherMatchIsEnough() {
        #expect(ClipboardExclusions.excludes(source: "com.apple.Safari", frontmost: "com.apple.Terminal", excluded: excluded))
    }

    /// Bundle identifiers are case-insensitive to Launch Services, so a list
    /// written by hand with other casing still works.
    @Test func matchingIgnoresCase() {
        #expect(ClipboardExclusions.excludes(source: nil, frontmost: "COM.APPLE.terminal", excluded: excluded))
    }

    @Test func nothingKnownMatchesNothing() {
        #expect(ClipboardExclusions.excludes(source: nil, frontmost: nil, excluded: excluded) == false)
        #expect(ClipboardExclusions.excludes(source: "", frontmost: "", excluded: ["", "x"]) == false)
    }

    // MARK: - Editing the list

    @Test func addingKeepsOrderAndRefusesDuplicates() {
        var list = ClipboardExclusions.adding(["com.b", "com.a"], to: [])
        #expect(list == ["com.b", "com.a"])
        list = ClipboardExclusions.adding(["COM.A", "com.c"], to: list)
        #expect(list == ["com.b", "com.a", "com.c"])
    }

    @Test func addingIgnoresBlankIdentifiers() {
        #expect(ClipboardExclusions.adding(["", "  "], to: ["com.a"]) == ["com.a"])
    }

    @Test func removingTakesOutOnlyThatOne() {
        #expect(ClipboardExclusions.removing("COM.A", from: ["com.b", "com.a", "com.c"]) == ["com.b", "com.c"])
    }

    // MARK: - Reading it back from the defaults

    @Test func absentReadsAsEmpty() {
        #expect(ClipboardExclusions.resolve(nil) == [])
    }

    /// The policy every preference resolver follows: a value of the wrong
    /// shape reads as the default and is left in place.
    @Test func theWrongTypeReadsAsEmpty() {
        #expect(ClipboardExclusions.resolve("com.apple.Terminal") == [])
        #expect(ClipboardExclusions.resolve(42) == [])
    }

    @Test func nonStringsAndDuplicatesInTheArrayAreDropped() {
        let raw: [Any] = ["com.a", 7, "COM.A", "", "com.b"]
        #expect(ClipboardExclusions.resolve(raw) == ["com.a", "com.b"])
    }
}
