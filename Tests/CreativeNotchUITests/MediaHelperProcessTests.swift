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

    // MARK: - Bounded shutdown (fix round 1: reviewer flagged unbounded
    // waitUntilExit as an indefinite main-thread hang)

    /// `performBoundedShutdown` is a pure state machine over injected
    /// closures — no `Process` involved — specifically so the SIGKILL
    /// escalation path is provably reachable in a test. A helper that
    /// traps or ignores SIGTERM (the exact scenario the review named)
    /// must still return in bounded time by escalating.
    @Test func stopEscalatesToSIGKILLWhenTheProcessIgnoresSIGTERM() {
        var terminateCalls = 0
        var waitCalls = 0
        var forceKillCalls = 0

        MediaHelperProcess.performBoundedShutdown(
            timeout: 0.001,
            terminate: { terminateCalls += 1 },
            waitForExit: { _ in
                waitCalls += 1
                // First call simulates SIGTERM being ignored (times out).
                // Second call simulates SIGKILL taking effect immediately.
                return waitCalls > 1
            },
            forceKill: { forceKillCalls += 1 }
        )

        #expect(terminateCalls == 1)
        #expect(forceKillCalls == 1)
        #expect(waitCalls == 2)
    }

    /// The complement: a process that exits promptly after SIGTERM must
    /// NOT be escalated to SIGKILL. Without this, a mutation that always
    /// force-kills regardless of `waitForExit`'s result would pass the
    /// test above for the wrong reason.
    @Test func stopDoesNotEscalateWhenTheProcessExitsPromptly() {
        var waitCalls = 0
        var forceKillCalls = 0

        MediaHelperProcess.performBoundedShutdown(
            timeout: 0.001,
            terminate: {},
            waitForExit: { _ in waitCalls += 1; return true },
            forceKill: { forceKillCalls += 1 }
        )

        #expect(waitCalls == 1)
        #expect(forceKillCalls == 0)
    }

    // MARK: - Stale post-stop delivery (fix round 1: reviewer flagged a
    // chunk mid-hop to the main actor publishing after stop() returns)

    /// `deliverFromReader` is what the real stdout reader calls after its
    /// `Task { @MainActor in ... }` hop. A chunk captured by the reader an
    /// instant before `stop()` runs can still be sitting on that hop when
    /// `stop()` finishes — this proves such a chunk is dropped rather than
    /// reaching `onLine` with data from a helper that's already gone.
    @Test func aChunkStillMidHopWhenStopFinishesIsNotPublished() {
        let helper = MediaHelperProcess()
        var lines: [String] = []
        helper.onLine = { lines.append($0) }

        helper.stop()
        helper.deliverFromReader("late\n")

        #expect(lines.isEmpty)
    }

    /// The complement: `deliverFromReader` must still forward a normal
    /// chunk when the helper has not been stopped, or the guard above
    /// would be trivially satisfied by a version that never delivers
    /// anything at all.
    @Test func deliverFromReaderForwardsNormallyWhenNotStopped() {
        let helper = MediaHelperProcess()
        var lines: [String] = []
        helper.onLine = { lines.append($0) }

        helper.deliverFromReader("fine\n")

        #expect(lines == ["fine"])
    }
}
