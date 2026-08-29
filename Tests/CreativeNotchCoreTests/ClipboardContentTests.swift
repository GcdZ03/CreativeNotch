import Foundation
import Testing
@testable import CreativeNotchCore

/// Spec section 5.3. The caps are the whole reason this type carries a
/// byte count: fifty entries live in RAM for the life of the process, so
/// an uncapped entry is an uncapped process.
struct ClipboardContentTests {

    // MARK: - Byte accounting

    /// UTF-8, not `count`. A string of emoji is four bytes per character
    /// and `count` would under-report it by a factor of four — which is
    /// the difference between a 1 MB cap and a 4 MB one.
    @Test func textIsMeasuredInUTF8Bytes() {
        #expect(ClipboardContent.text("abc").byteCount == 3)
        #expect(ClipboardContent.text("🎛️").byteCount == "🎛️".utf8.count)
        #expect(ClipboardContent.text("🎛️").byteCount > "🎛️".count)
    }

    @Test func imagesAreMeasuredByTheirData() {
        let data = Data(repeating: 0, count: 4096)
        #expect(ClipboardContent.image(data, ext: "png").byteCount == 4096)
    }

    @Test func emptyContentCostsNothing() {
        #expect(ClipboardContent.text("").byteCount == 0)
        #expect(ClipboardContent.image(Data(), ext: "png").byteCount == 0)
    }

    // MARK: - Blankness

    /// Whitespace-only text is what a stray select-and-copy produces. The
    /// shelf already refuses it (`Pasteboard+Drop`); the ring does too, so
    /// a fifty-slot history cannot fill with blank lines.
    @Test func whitespaceOnlyTextIsBlank() {
        #expect(ClipboardContent.text("").isBlank)
        #expect(ClipboardContent.text("   \n\t ").isBlank)
        #expect(ClipboardContent.text(" x ").isBlank == false)
    }

    @Test func anImageIsBlankOnlyWhenItHasNoBytes() {
        #expect(ClipboardContent.image(Data(), ext: "png").isBlank)
        #expect(ClipboardContent.image(Data([0x89]), ext: "png").isBlank == false)
    }

    // MARK: - Limits

    @Test func theCapsAreWhatTheSpecSays() {
        #expect(ClipboardLimits.maxTextBytes == 1_000_000)
        #expect(ClipboardLimits.maxImageBytes == 10_000_000)
    }

    /// Exactly at the cap is accepted; one byte over is not. Without this
    /// pair, `<` and `<=` are indistinguishable.
    @Test func theTextBoundaryIsInclusive() {
        #expect(ClipboardLimits.acceptsText(byteCount: ClipboardLimits.maxTextBytes))
        #expect(ClipboardLimits.acceptsText(byteCount: ClipboardLimits.maxTextBytes + 1) == false)
    }

    @Test func theImageBoundaryIsInclusive() {
        #expect(ClipboardLimits.acceptsImage(byteCount: ClipboardLimits.maxImageBytes))
        #expect(ClipboardLimits.acceptsImage(byteCount: ClipboardLimits.maxImageBytes + 1) == false)
    }

    /// The caps differ by an order of magnitude, so applying the wrong one
    /// to the wrong kind is a real mistake with no compiler help. A 5 MB
    /// image is fine; 5 MB of text is not.
    @Test func eachKindGetsItsOwnCap() {
        let fiveMB = 5_000_000
        #expect(ClipboardLimits.accepts(.image(Data(repeating: 0, count: fiveMB), ext: "png")))
        #expect(ClipboardLimits.accepts(.text(String(repeating: "a", count: fiveMB))) == false)
    }

    @Test func blankContentIsNeverAccepted() {
        #expect(ClipboardLimits.accepts(.text("  ")) == false)
        #expect(ClipboardLimits.accepts(.image(Data(), ext: "png")) == false)
    }

    @Test func ordinaryContentIsAccepted() {
        #expect(ClipboardLimits.accepts(.text("hello there")))
        #expect(ClipboardLimits.accepts(.image(Data(repeating: 7, count: 1024), ext: "png")))
    }

    // MARK: - Equality

    /// Promotion in `ClipboardStore` is driven by content equality, so
    /// this is load-bearing rather than incidental.
    @Test func identicalContentComparesEqual() {
        #expect(ClipboardContent.text("a") == ClipboardContent.text("a"))
        #expect(ClipboardContent.text("a") != ClipboardContent.text("b"))

        let data = Data([1, 2, 3])
        #expect(ClipboardContent.image(data, ext: "png") == .image(data, ext: "png"))
        #expect(ClipboardContent.image(data, ext: "png") != .image(data, ext: "tiff"))
        #expect(ClipboardContent.image(data, ext: "png") != .image(Data([1, 2]), ext: "png"))
    }

    @Test func textAndImagesAreNeverEqual() {
        #expect(ClipboardContent.text("x") != .image(Data([1]), ext: "png"))
    }
}
