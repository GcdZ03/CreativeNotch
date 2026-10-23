import Foundation
import Testing
@testable import CreativeNotchCore

/// Reassembles newline-delimited output from arbitrary chunks.
///
/// `FileHandle.readabilityHandler` hands over whatever bytes exist at that
/// moment — never whole lines. A payload split across two reads is the
/// normal case for anything larger than a pipe buffer, and artwork makes
/// these lines large. Handling it inline in the reader is how this bug
/// hides for months and then appears only for long titles.
struct LineBufferTests {

    @Test func aWholeLineIsReturnedImmediately() {
        var b = LineBuffer()
        #expect(b.append("hello\n") == ["hello"])
    }

    @Test func severalLinesInOneChunkAllReturn() {
        var b = LineBuffer()
        #expect(b.append("a\nb\nc\n") == ["a", "b", "c"])
    }

    /// The case this type exists for.
    @Test func aLineSplitAcrossChunksIsRejoined() {
        var b = LineBuffer()
        #expect(b.append("{\"tit") == [])
        #expect(b.append("le\":\"x\"}") == [])
        #expect(b.append("\n") == ["{\"title\":\"x\"}"])
    }

    /// A chunk boundary landing exactly on the newline must not produce an
    /// empty line or lose the next one.
    @Test func aChunkEndingOnTheNewlineIsClean() {
        var b = LineBuffer()
        #expect(b.append("one\n") == ["one"])
        #expect(b.append("two\n") == ["two"])
    }

    @Test func aTrailingPartialLineIsHeldNotEmitted() {
        var b = LineBuffer()
        #expect(b.append("complete\npartial") == ["complete"])
        #expect(b.pending == "partial")
    }

    /// Blank lines carry no payload and must not reach the decoder as
    /// empty strings it then has to special-case.
    @Test func blankLinesAreDropped() {
        var b = LineBuffer()
        #expect(b.append("a\n\n\nb\n") == ["a", "b"])
    }

    /// A helper restart must not glue the dead process's half-line onto the
    /// new one's first line, which would corrupt exactly one payload per
    /// restart — rare, and maddening to diagnose.
    @Test func resetDropsThePartialLine() {
        var b = LineBuffer()
        _ = b.append("half a li")
        b.reset()
        #expect(b.pending.isEmpty)
        #expect(b.append("ne\n") == ["ne"])
    }

    // MARK: - Bytes, not strings

    /// `readabilityHandler` cuts wherever the pipe happened to be, which is
    /// byte-aligned, not character-aligned. A title with an emoji or an
    /// accented letter straddling a read boundary used to arrive as two
    /// halves of invalid UTF-8; decoding each chunk on its own returned
    /// `nil` and the whole chunk — newline included — was dropped.
    @Test func aMultibyteCharacterSplitAcrossChunksIsRejoined() {
        var b = LineBuffer()
        let line = "{\"title\":\"caf\u{E9} \u{1F3B5}\"}"
        let bytes = Array((line + "\n").utf8)
        // Cut inside the four-byte emoji, so neither half is valid UTF-8.
        let cut = bytes.count - 4
        #expect(b.append(Data(bytes[..<cut])) == [])
        #expect(b.append(Data(bytes[cut...])) == [line])
    }

    /// Splitting on byte 0x0A is safe precisely because UTF-8 never uses
    /// that byte inside a multibyte sequence — every continuation byte has
    /// its high bit set.
    @Test func everySingleByteCutOfAMultibyteLineReassembles() {
        let line = "\u{1F3B5} \u{E9}\u{4E2D}\u{6587}"
        let bytes = Array((line + "\n").utf8)
        for cut in 1..<bytes.count {
            var b = LineBuffer()
            let first = b.append(Data(bytes[..<cut]))
            let second = b.append(Data(bytes[cut...]))
            #expect(first + second == [line], "cut at byte \(cut)")
        }
    }

    /// The byte count the reader's cap is checked against.
    @Test func pendingByteCountCountsBytesNotCharacters() {
        var b = LineBuffer()
        _ = b.append("\u{1F3B5}")
        #expect(b.pendingByteCount == 4)
    }

    /// A 1 MB artwork line arrives as hundreds of pipe-sized chunks. Each
    /// chunk must be scanned once for its newline — rescanning everything
    /// already held back makes one line cost the square of its length.
    @Test func eachByteIsScannedOnceHoweverManyChunksALineTakes() {
        var b = LineBuffer()
        let chunk = String(repeating: "x", count: 1024)
        let chunks = 512
        for _ in 0..<chunks { _ = b.append(chunk) }
        #expect(b.append("\n") == [String(repeating: "x", count: 1024 * chunks)])
        #expect(b.bytesScanned == 1024 * chunks + 1)
    }

    /// The scan offset must not survive a reset, or the next line's first
    /// bytes would be skipped and its newline missed.
    @Test func resetAlsoForgetsHowFarItHadScanned() {
        var b = LineBuffer()
        _ = b.append("a long partial line")
        b.reset()
        #expect(b.append("x\n") == ["x"])
    }
}

/// The tests above were written against `String` chunks; the buffer takes
/// the raw bytes a pipe delivers. Kept here rather than in the module, so
/// production code has exactly one way in.
extension LineBuffer {
    mutating func append(_ chunk: String) -> [String] {
        append(Data(chunk.utf8))
    }
}
