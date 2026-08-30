import Dispatch
import Foundation
import CreativeNotchCore

/// Spawns the `media-helper.pl` subprocess and turns its stdout into
/// lines.
///
/// The helper exists only to be an Apple-signed host process — see
/// `Sources/CreativeNotchMediaBridge/bridge.m` for why that matters. This
/// type knows nothing about *why* it's perl; it just runs
/// `/usr/bin/perl script.pl dylib.dylib`, reads newline-delimited JSON off
/// its stdout, and hands complete lines to `onLine`.
///
/// `ingest(_:)` is the seam the test suite drives directly with the byte
/// chunks a real `readabilityHandler` would deliver, which is what keeps
/// `Process` out of every test in this module — spawning the real helper
/// would read the developer's live media state and could leave a stray
/// process behind. See `MediaHelperProcessTests`.
@MainActor
public final class MediaHelperProcess {

    /// Ceiling on a single line, complete or still pending.
    ///
    /// Artwork is base64 with no size ceiling enforced by the bridge; a
    /// real payload was measured at 288 KB. Without a cap, a hostile or
    /// malfunctioning payload becomes an unbounded buffer in THIS process,
    /// not just a slow one in the helper. 1 MB is generous headroom over
    /// the observed 288 KB while still being a hard stop.
    static let maxLineLength = 1_048_576

    /// Bound on how long `stop()` will wait for the child to exit before
    /// escalating — first after SIGTERM, then again after SIGKILL. See
    /// `performBoundedShutdown` for why this exists at all.
    static let shutdownTimeout: TimeInterval = 1.0

    public var onLine: ((String) -> Void)?
    public var onExit: ((Int32) -> Void)?

    public private(set) var isRunning = false

    /// How many lines have been dropped for exceeding `maxLineLength`,
    /// complete or never-terminated. Counted, never logged — the count
    /// says something is wrong; the contents are user data (a title or
    /// artist) that must never reach a log.
    private(set) var discardedLineCount = 0

    /// Guards against a specific race: the stdout `readabilityHandler`
    /// runs on a background queue and hops to the main actor with
    /// `Task { @MainActor in ... }` before calling `deliverFromReader`. A
    /// chunk can be captured by that handler an instant before `stop()`
    /// runs, and its `Task` can still be sitting on the main actor's queue
    /// when `stop()` finishes — meaning it executes AFTER the buffer has
    /// already been reset, and would otherwise publish one stale line per
    /// stop. Checked only by `deliverFromReader`, never by `ingest`
    /// itself: a direct call to `ingest` right after `stop()` is a
    /// deliberate, synchronous reuse of the helper (see
    /// `stoppingDiscardsAPartialLine`), not the asynchronous race this
    /// exists to close.
    private var isStopped = false

    private var buffer = LineBuffer()
    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    /// The child's stdin, held for as long as the helper runs.
    ///
    /// This is not decoration and it is not optional. `bridge.m` watches
    /// its stdin for EOF and calls `exit(0)` the moment it reads zero
    /// bytes — that watchdog is the *only* thing guaranteeing no helper
    /// outlives the app (spec section 4), because a crashed parent runs no
    /// cleanup code. Both directions of that contract depend on this
    /// process owning the write end:
    ///
    /// - Leave it unset and the child inherits OUR fd 0. A `.app` launched
    ///   by `open` or launchd has fd 0 = `/dev/null`, which is readable and
    ///   immediately at EOF, so the watchdog fires within milliseconds of
    ///   every spawn, the supervisor burns its whole backoff budget, and
    ///   the feature never works in a shipped app. It survives only when
    ///   run from a terminal, where fd 0 is a tty — which is exactly why
    ///   every by-hand check passed.
    /// - Inherited-tty stdin is the mirror-image failure: nothing closes on
    ///   our death, so no EOF ever arrives and the helper genuinely does
    ///   outlive us.
    ///
    /// Retaining the `Pipe` keeps its write end open for the process's
    /// lifetime; closing it (`closeStandardInput`) is what delivers the
    /// EOF. Do not "tidy" this into a local in `start()`.
    private(set) var stdinPipe: Pipe?

    public init() {}

    /// The helper's script and dylib as they ship inside the app bundle,
    /// or `nil` unless BOTH exist.
    ///
    /// Under `swift test` and `swift run` there is no `.app` bundle, so
    /// `Bundle.main` is the test runner or bare executable and these paths
    /// never resolve — that is precisely what stops the test suite (and a
    /// bare `swift run`) from spawning a real helper. Do not special-case
    /// a test environment here; the absence of a bundle is the guard.
    public static var bundledPaths: (script: String, dylib: String)? {
        let script = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/media-helper.pl")
            .path
        // Perl is a hardened program and rejects a relative dylib path
        // outright, so this MUST stay an absolute path built from the
        // bundle's URL — never a bare resource name.
        let dylib = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Frameworks/libCreativeNotchMediaBridge.dylib")
            .path

        guard
            FileManager.default.fileExists(atPath: script),
            FileManager.default.fileExists(atPath: dylib)
        else { return nil }

        return (script: script, dylib: dylib)
    }

    public static var isAvailable: Bool { bundledPaths != nil }

    /// Starts the helper, or does nothing if it's already running or the
    /// bundle doesn't carry it.
    public func start() {
        guard !isRunning else { return }
        guard let paths = Self.bundledPaths else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [paths.script, paths.dylib]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        attachStandardIO(to: process, stdout: stdoutPipe, stderr: stderrPipe)

        // `readabilityHandler` fires on a background queue, never the
        // main actor. Hop over explicitly rather than touching `self`
        // from here — `ingest` mutates actor-isolated state.
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                self?.deliverFromReader(chunk)
            }
        }

        // Drained ONLY to keep the pipe from filling and blocking the
        // child — never forwarded to `onLine`, never logged. stderr is
        // diagnostics, and diagnostics from this helper can quote a track
        // title.
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }

        process.terminationHandler = { [weak self] terminated in
            let status = terminated.terminationStatus
            Task { @MainActor in
                self?.handleUnexpectedExit(status: status)
            }
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            // Nothing was spawned, so nothing is owed an EOF — but the
            // pipe must not be left behind for a later `stop()` to close
            // on behalf of a process that never existed.
            closeStandardInput()
            return
        }

        self.process = process
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
        isRunning = true
        isStopped = false
    }

    /// Stops the helper.
    ///
    /// The helper is documented to exit once its stdin closes, which
    /// makes "just close stdin" look like the tidy way to shut it down.
    /// Resist that. This process must keep draining stdout for as long as
    /// the child might still be writing — a 288 KB artwork line saturates
    /// a pipe buffer easily — or a write can block on a full pipe with
    /// nobody left reading it, and the child never gets back around to
    /// noticing stdin closed because it's stuck before that check. The
    /// bridge's own EOF watchdog runs on its own queue today, which makes
    /// that specific hang unlikely here, but that is a property of
    /// today's bridge, not of this method, so this method does not lean
    /// on it: terminate the process explicitly and only tear the reading
    /// down once it is confirmed gone — see `performBoundedShutdown` for
    /// why "confirmed gone" is itself bounded rather than an unbounded
    /// `waitUntilExit()`.
    public func stop() {
        // First, and unconditionally: the child is documented to exit on
        // stdin EOF, so give it the chance to leave on its own before
        // signals get involved. Unconditional because a helper that was
        // configured but never successfully spawned must not leave a
        // dangling write end behind either.
        closeStandardInput()

        if let process {
            // This is a deliberate stop, not an unexpected death — don't
            // also fire onExit for it.
            process.terminationHandler = nil

            let exited = DispatchSemaphore(value: 0)
            var waiterStarted = false

            Self.performBoundedShutdown(
                timeout: Self.shutdownTimeout,
                terminate: { process.terminate() },
                waitForExit: { timeout in
                    // Started lazily, on the first call, and shared across
                    // both possible calls (the SIGTERM grace period and,
                    // only if that timed out, the SIGKILL grace period) —
                    // exactly one background call to `waitUntilExit()`,
                    // never two concurrent ones.
                    if !waiterStarted {
                        waiterStarted = true
                        DispatchQueue.global(qos: .userInitiated).async {
                            process.waitUntilExit()
                            exited.signal()
                        }
                    }
                    return exited.wait(timeout: .now() + timeout) == .success
                },
                forceKill: { kill(process.processIdentifier, SIGKILL) }
            )

            stdoutPipe?.fileHandleForReading.readabilityHandler = nil
            stderrPipe?.fileHandleForReading.readabilityHandler = nil

            self.process = nil
            self.stdoutPipe = nil
            self.stderrPipe = nil
            isRunning = false
        }

        // Block any chunk still mid-hop from the background reader (see
        // `isStopped`'s doc comment) before resetting the buffer it would
        // otherwise be appended to.
        isStopped = true

        // A restart must not glue the dead helper's half-written line
        // onto the new one's first line — that corrupts exactly one
        // payload per restart. Unconditional: even a helper that was
        // never started (or already stopped) must not let a previously
        // ingested partial line survive a `stop()` call.
        buffer.reset()
    }

    /// Points the child's three standard streams at pipes we own, and
    /// retains the stdin pipe.
    ///
    /// Split out of `start()` and written against a protocol rather than
    /// `Process` for one reason: `start()` cannot run under `swift test`
    /// (there is no app bundle, so `bundledPaths` is `nil`) and no test in
    /// this module may construct a `Process`. Without this seam the single
    /// most consequential line in the file — `standardInput` — would be
    /// unprovable, which is precisely how it came to be missing.
    func attachStandardIO(to target: any HelperProcessIO, stdout: Pipe, stderr: Pipe) {
        let stdin = Pipe()
        target.standardInput = stdin
        target.standardOutput = stdout
        target.standardError = stderr
        stdinPipe = stdin
    }

    /// Closes the write end of the child's stdin — the EOF `bridge.m`'s
    /// watchdog is waiting for — and drops the pipe.
    ///
    /// Explicit rather than relying on deinit: releasing the last
    /// reference would close the descriptor too, but *when* the child
    /// learns we are done is the entire point, and that must not depend on
    /// whether some other object still holds the pipe.
    func closeStandardInput() {
        // Throws if it is already closed; there is nothing to do about
        // that and nothing to report.
        try? stdinPipe?.fileHandleForWriting.close()
        stdinPipe = nil
    }

    /// Sends SIGTERM, waits up to `timeout` for exit, and escalates to
    /// SIGKILL if the process is still alive afterward.
    ///
    /// A pure state machine over injected `terminate` / `waitForExit` /
    /// `forceKill` closures — the same closure-injection `MediaKeyMonitor`
    /// uses for its event tap — specifically so the escalation path is
    /// provably reachable in a test without ever spawning a real process.
    /// That is not a hypothetical: a media process wedged beyond recovery
    /// during this very session, which is exactly the failure mode this
    /// guards against. `Process.terminate()` sends SIGTERM, and SIGTERM
    /// can be trapped, blocked, or simply ignored by a wedged or
    /// misbehaving child — "usually terminates" is not an acceptable
    /// basis for a call that blocks the main actor. SIGKILL cannot be
    /// caught, blocked, or ignored by any process, so it is the only
    /// signal that guarantees this function returns in bounded time. Do
    /// not remove it as belt-and-braces — it is the actual guarantee.
    static func performBoundedShutdown(
        timeout: TimeInterval,
        terminate: () -> Void,
        waitForExit: (TimeInterval) -> Bool,
        forceKill: () -> Void
    ) {
        terminate()
        if waitForExit(timeout) { return }
        forceKill()
        _ = waitForExit(timeout)
    }

    private func handleUnexpectedExit(status: Int32) {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        // The child is already gone, so this is not about EOF any more —
        // it is about not leaking a file descriptor pair per crash. The
        // supervisor restarts after a crash, and a helper that dies four
        // times before degrading would otherwise strand four write ends.
        closeStandardInput()
        process = nil
        stdoutPipe = nil
        stderrPipe = nil
        isRunning = false
        isStopped = true
        buffer.reset()
        onExit?(status)
    }

    /// Entry point for the stdout reader, after its hop to the main
    /// actor. See `isStopped` for why this check lives here rather than
    /// inside `ingest` itself.
    func deliverFromReader(_ chunk: String) {
        guard !isStopped else { return }
        ingest(chunk)
    }

    /// Feeds one chunk of raw stdout into the line buffer and forwards
    /// every complete, in-bounds line to `onLine`.
    ///
    /// Internal, not private: this is the only method the test suite
    /// touches, driven with the exact chunks a real `readabilityHandler`
    /// would deliver, so no test needs to spawn a process.
    func ingest(_ chunk: String) {
        let lines = buffer.append(chunk)
        for line in lines {
            if line.utf8.count > Self.maxLineLength {
                discardedLineCount += 1
                continue
            }
            onLine?(line)
        }

        // A line that never finds its newline is the dangerous case: with
        // no check here, it would grow without bound as long as the
        // helper (or an attacker who controls it) kept writing. Reset the
        // buffer once pending data alone exceeds the cap, well before any
        // newline arrives, so the NEXT line still parses correctly.
        if buffer.pending.utf8.count > Self.maxLineLength {
            discardedLineCount += 1
            buffer.reset()
        }
    }
}

/// The slice of `Process` that `MediaHelperProcess.attachStandardIO`
/// configures.
///
/// A protocol, not `Process` itself, so the stdin assignment is testable
/// without spawning or even constructing a process — see
/// `attachStandardIO`. `Process` already declares all three as `Any?`, so
/// it conforms with an empty extension.
protocol HelperProcessIO: AnyObject {
    var standardInput: Any? { get set }
    var standardOutput: Any? { get set }
    var standardError: Any? { get set }
}

extension Process: HelperProcessIO {}
