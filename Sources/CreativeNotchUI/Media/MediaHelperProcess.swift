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

    public var onLine: ((String) -> Void)?
    public var onExit: ((Int32) -> Void)?

    public private(set) var isRunning = false

    /// How many lines have been dropped for exceeding `maxLineLength`,
    /// complete or never-terminated. Counted, never logged — the count
    /// says something is wrong; the contents are user data (a title or
    /// artist) that must never reach a log.
    private(set) var discardedLineCount = 0

    private var buffer = LineBuffer()
    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

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
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // `readabilityHandler` fires on a background queue, never the
        // main actor. Hop over explicitly rather than touching `self`
        // from here — `ingest` mutates actor-isolated state.
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                self?.ingest(chunk)
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
            return
        }

        self.process = process
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
        isRunning = true
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
    /// down once `waitUntilExit` confirms it is actually gone.
    public func stop() {
        if let process {
            // This is a deliberate stop, not an unexpected death — don't
            // also fire onExit for it.
            process.terminationHandler = nil
            process.terminate()
            process.waitUntilExit()

            stdoutPipe?.fileHandleForReading.readabilityHandler = nil
            stderrPipe?.fileHandleForReading.readabilityHandler = nil

            self.process = nil
            self.stdoutPipe = nil
            self.stderrPipe = nil
            isRunning = false
        }

        // A restart must not glue the dead helper's half-written line
        // onto the new one's first line — that corrupts exactly one
        // payload per restart. Unconditional: even a helper that was
        // never started (or already stopped) must not let a previously
        // ingested partial line survive a `stop()` call.
        buffer.reset()
    }

    private func handleUnexpectedExit(status: Int32) {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        process = nil
        stdoutPipe = nil
        stderrPipe = nil
        isRunning = false
        buffer.reset()
        onExit?(status)
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
