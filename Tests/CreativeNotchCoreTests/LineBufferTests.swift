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
}
