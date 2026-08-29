import Foundation
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// Views are not unit-tested in this project, so the pure formatting they
/// lean on is pulled out and tested instead.
struct ClipboardPreviewTests {

    @Test func shortTextIsShownWhole() {
        #expect(ClipboardPreview.text(for: .text("hello there")) == "hello there")
    }

    /// A 1 MB entry is legal (spec section 5.3), and the notch is a few
    /// hundred points wide. Truncating here is a display concern only —
    /// the stored entry is untouched, so pasting it back is complete.
    @Test func longTextIsTruncatedForDisplay() {
        let long = String(repeating: "a", count: ClipboardPreview.maxCharacters + 50)
        let preview = ClipboardPreview.text(for: .text(long))

        #expect(preview.count <= ClipboardPreview.maxCharacters + 1)
        #expect(preview.hasSuffix("…"))
    }

    @Test func textExactlyAtTheLimitIsNotTruncated() {
        let exact = String(repeating: "b", count: ClipboardPreview.maxCharacters)
        #expect(ClipboardPreview.text(for: .text(exact)) == exact)
    }

    /// Newlines are collapsed: a copied code block would otherwise render
    /// as one very tall row and push everything else off the panel.
    @Test func newlinesAreCollapsedIntoSpaces() {
        #expect(ClipboardPreview.text(for: .text("one\ntwo\r\nthree")) == "one two three")
    }

    @Test func surroundingWhitespaceIsTrimmed() {
        #expect(ClipboardPreview.text(for: .text("  padded  ")) == "padded")
    }

    @Test func runsOfWhitespaceCollapse() {
        #expect(ClipboardPreview.text(for: .text("a     b")) == "a b")
    }

    /// Images have no text, so the preview describes them instead.
    @Test func imagesAreDescribedByTheirFormat() {
        #expect(ClipboardPreview.text(for: .image(Data(repeating: 0, count: 2048), ext: "png")) == "PNG image")
        #expect(ClipboardPreview.text(for: .image(Data(repeating: 0, count: 10), ext: "tiff")) == "TIFF image")
    }
}
