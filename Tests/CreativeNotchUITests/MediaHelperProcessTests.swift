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

/// Stands in for `Process` in the stdin tests below.
///
/// The rule "no `Process` in this file" is what makes the whole module
/// safe to test, but it also hid the branch's worst bug: the line that
/// assigns `standardInput` was simply absent, and nothing in 471 tests
/// could see the absence. `MediaHelperProcess.attachStandardIO` takes this
/// protocol so that assignment is observable without a real process.
private final class FakeProcessIO: HelperProcessIO {
    var standardInput: Any?
    var standardOutput: Any?
    var standardError: Any?
}

/// The child's stdin — the contract `bridge.m` documents and the Swift side
/// did not honour.
///
/// The bug these exist for: `standardInput` was never set, so the child
/// inherited the app's fd 0. In a shipped `.app` (launched by `open` or
/// launchd) that is `/dev/null`, which reads EOF immediately, so the
/// bridge's stdin watchdog called `exit(0)` within milliseconds of every
/// spawn and the supervisor degraded permanently. Launched from a terminal
/// fd 0 is a tty, so it survived — which is why every by-hand check passed
/// and the feature still never worked for a user.
@MainActor
struct MediaHelperStandardInputTests {

    /// Whether the pipe's read end is at EOF, from the child's point of
    /// view, without blocking.
    ///
    /// `FileHandle.fileDescriptor` raises an Objective-C exception once
    /// closed (it crashes the whole test process, not just one test), and
    /// `readDataToEndOfFile()` would block forever if the fix regressed —
    /// a hung suite instead of a red test. `poll` with a zero timeout
    /// answers the only question that matters: does the reader see the
    /// write end as gone? Nothing ever writes into this pipe, so any
    /// readable or hung-up event means EOF.
    static func readEndSeesEOF(_ pipe: Pipe) -> Bool {
        var descriptor = pollfd(
            fd: pipe.fileHandleForReading.fileDescriptor,
            events: Int16(POLLIN),
            revents: 0
        )
        return poll(&descriptor, 1, 0) > 0
    }

    @Test func aFreshHelperHoldsNoStdinPipe() {
        #expect(MediaHelperProcess().stdinPipe == nil)
    }

    /// The assignment itself. Delete `target.standardInput = stdin` and
    /// this is the test that goes red.
    @Test func attachingStandardIOGivesTheChildAPipeForItsStdin() {
        let helper = MediaHelperProcess()
        let fake = FakeProcessIO()

        helper.attachStandardIO(to: fake, stdout: Pipe(), stderr: Pipe())

        #expect(fake.standardInput is Pipe)
    }

    /// A pipe handed to the child and then dropped on the floor would be
    /// closed by ARC the instant `start()` returned — an EOF at spawn time,
    /// which is the very failure being fixed. The parent must hold the
    /// write end open for the child's whole life.
    @Test func theStdinPipeIsRetainedByTheHelperNotJustHandedOver() throws {
        let helper = MediaHelperProcess()
        let fake = FakeProcessIO()

        helper.attachStandardIO(to: fake, stdout: Pipe(), stderr: Pipe())

        let retained = try #require(helper.stdinPipe)
        #expect(fake.standardInput as AnyObject === retained)
        // The child's view: nothing readable and no hangup, because the
        // parent still holds the write end. This is the exact condition
        // `bridge.m`'s watchdog blocks on, so asserting it is asserting
        // "the helper stays alive".
        #expect(Self.readEndSeesEOF(retained) == false)
    }

    /// stdout and stderr must survive the refactor that introduced the
    /// stdin pipe — losing the stdout pipe would silently end the feed.
    @Test func attachingStandardIOAlsoWiresStdoutAndStderr() {
        let helper = MediaHelperProcess()
        let fake = FakeProcessIO()
        let out = Pipe()
        let err = Pipe()

        helper.attachStandardIO(to: fake, stdout: out, stderr: err)

        #expect(fake.standardOutput as AnyObject === out)
        #expect(fake.standardError as AnyObject === err)
    }

    /// `stop()` must actually close the write end. Merely releasing the
    /// reference would usually do it, but "usually" depends on nobody else
    /// holding the pipe — and the EOF is what tells the child to exit, so
    /// its timing cannot be left to whoever drops the last reference.
    @Test func stoppingClosesTheChildsStdinAndReleasesThePipe() throws {
        let helper = MediaHelperProcess()
        let fake = FakeProcessIO()
        helper.attachStandardIO(to: fake, stdout: Pipe(), stderr: Pipe())
        let pipe = try #require(helper.stdinPipe)

        helper.stop()

        #expect(helper.stdinPipe == nil)
        // And now the child's read end is at EOF — the signal `bridge.m`
        // exits on. Nothing is ever written into this pipe, so a readable
        // or hung-up read end can only mean the write end is gone.
        #expect(Self.readEndSeesEOF(pipe))
    }

    /// Closing twice must not trap. `stop()` is called on quit, on the
    /// activity gate, and by the supervisor — including on a helper that
    /// was already stopped.
    @Test func closingStandardInputTwiceIsHarmless() {
        let helper = MediaHelperProcess()
        helper.attachStandardIO(to: FakeProcessIO(), stdout: Pipe(), stderr: Pipe())

        helper.stop()
        helper.stop()

        #expect(helper.stdinPipe == nil)
    }
}
