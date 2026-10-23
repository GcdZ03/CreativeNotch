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

/// The row's trailing label and spoken label. The view only swaps strings
/// and runs a one-shot delay; which string wins is decided here.
struct ClipboardRowModelTests {

    /// The action writes the entry to the pasteboard and nothing more —
    /// the app has no Accessibility permission, so it cannot paste. The
    /// verb on the row has to say what actually happens.
    @Test func theHoverVerbIsCopy() {
        #expect(ClipboardRowModel.trailingText(time: "10:42", hovering: true, copied: false) == "Copy")
    }

    @Test func atRestTheRowShowsItsTime() {
        #expect(ClipboardRowModel.trailingText(time: "10:42", hovering: false, copied: false) == "10:42")
    }

    /// The confirmation outranks the hover verb: the pointer is still on
    /// the row it just clicked, and "Copy" there would read as nothing
    /// having happened.
    @Test func theConfirmationOutranksHover() {
        #expect(ClipboardRowModel.trailingText(time: "10:42", hovering: true, copied: true) == "Copied ✓")
        #expect(ClipboardRowModel.trailingText(time: "10:42", hovering: false, copied: true) == "Copied ✓")
    }

    /// Long enough to read, short enough that it is gone before the next
    /// thing the user does.
    @Test func theConfirmationIsBrief() {
        #expect(ClipboardRowModel.confirmationDuration == .milliseconds(1200))
    }

    @Test func voiceOverHearsTheVerbCopy() {
        let entry = ClipboardEntry(id: UUID(), content: .text("hello"), addedAt: Date())
        let label = ClipboardRowModel.accessibilityLabel(entry: entry, time: "10:42")
        #expect(label == "Copy hello, added 10:42")
        #expect(label.contains("Paste") == false)
    }

    @Test func theAnnouncementSaysCopied() {
        #expect(ClipboardRowModel.copiedAnnouncement == "Copied")
    }
}
