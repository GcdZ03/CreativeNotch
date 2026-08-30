import AppKit
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// Spawning the helper and reading its output.
///
/// **No test here starts a real process.** `Process` must not appear in
/// this file. What is tested is `ingest` — the seam between the pipe and
/// the rest of the app — driven directly with the chunks a real
/// `readabilityHandler` would deliver. The real spawn is verified by hand
/// in Task 6 and Task 10.
@MainActor
struct MediaHelperProcessTests {

    @Test func aWholeLineIsForwarded() {
        let helper = MediaHelperProcess()
        var lines: [String] = []
        helper.onLine = { lines.append($0) }

        helper.ingest("{\"title\":\"x\"}\n")

        #expect(lines == ["{\"title\":\"x\"}"])
    }

    /// Artwork makes payloads far larger than a pipe buffer, so splitting
    /// is the normal case rather than an edge one.
    @Test func aSplitLineIsForwardedOnceComplete() {
        let helper = MediaHelperProcess()
        var lines: [String] = []
        helper.onLine = { lines.append($0) }

        helper.ingest("{\"tit")
        #expect(lines.isEmpty)
        helper.ingest("le\":\"x\"}\n")

        #expect(lines == ["{\"title\":\"x\"}"])
    }

    @Test func severalLinesInOneChunkAllForward() {
        let helper = MediaHelperProcess()
        var count = 0
        helper.onLine = { _ in count += 1 }

        helper.ingest("a\nb\nc\n")

        #expect(count == 3)
    }

    /// A restart must not glue the dead helper's half-line onto the new
    /// one's first line — that corrupts exactly one payload per restart.
    @Test func stoppingDiscardsAPartialLine() {
        let helper = MediaHelperProcess()
        var lines: [String] = []
        helper.onLine = { lines.append($0) }

        helper.ingest("half")
        helper.stop()
        helper.ingest("rest\n")

        #expect(lines == ["rest"])
    }

    /// Under `swift test` there is no app bundle, so the paths cannot
    /// resolve and the module MUST report unavailable. This is what
    /// guarantees the suite never spawns a helper — an earlier draft
    /// asserted `isAvailable == (bundledPaths != nil)`, which compares the
    /// implementation to itself and cannot fail. Do not restore that.
    @Test func theHelperIsUnavailableOutsideAnAppBundle() {
        #expect(MediaHelperProcess.isAvailable == false)
        #expect(MediaHelperProcess.bundledPaths == nil)
    }

    @Test func aFreshHelperIsNotRunning() {
        #expect(MediaHelperProcess().isRunning == false)
    }

    // MARK: - Maximum line length (task 6 review follow-up)

    /// Artwork is base64 with no size ceiling in the bridge; a real
    /// payload was measured at 288 KB. A single already-terminated line
    /// that exceeds the cap must be dropped rather than handed to
    /// `onLine`, and recovery — parsing the next, well-formed line — is
    /// the part that actually matters: a reader that drops the line but
    /// never recovers is just a slower way to wedge the stream.
    @Test func anOverlongCompleteLineIsDroppedAndTheReaderRecovers() {
        let helper = MediaHelperProcess()
        var lines: [String] = []
        helper.onLine = { lines.append($0) }

        let overlong = String(repeating: "a", count: MediaHelperProcess.maxLineLength + 1)
        helper.ingest(overlong + "\n")
        helper.ingest("next line\n")

        #expect(lines == ["next line"])
        #expect(helper.discardedLineCount == 1)
    }

    /// The dangerous case isn't a complete oversized line — it's a
    /// payload that never finds its newline. Without a cap on the
    /// *pending* buffer, this becomes an unbounded allocation for as long
    /// as a hostile or malfunctioning helper keeps writing. The buffer
    /// must be reset once the pending data alone exceeds the cap, well
    /// before any newline arrives, and the next real line must still
    /// parse correctly afterward.
    @Test func aNeverTerminatedOverlongLineIsDroppedAndTheReaderRecovers() {
        let helper = MediaHelperProcess()
        var lines: [String] = []
        helper.onLine = { lines.append($0) }

        let hugeNoNewline = String(repeating: "b", count: MediaHelperProcess.maxLineLength + 1)
        helper.ingest(hugeNoNewline)
        helper.ingest("next line\n")

        #expect(lines == ["next line"])
        #expect(helper.discardedLineCount == 1)
    }
}
