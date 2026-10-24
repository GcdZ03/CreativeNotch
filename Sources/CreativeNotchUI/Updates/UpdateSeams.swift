import Foundation
import CreativeNotchCore

// Everything the updater reaches outside the process, behind a protocol
// each (2026-10-24): the network, the tools it runs and the file moves.
// The real ones are handed in only by `AppDelegate.configureForRealLaunch()`;
// every delegate a test builds gets the inert ones, so no test can fetch,
// replace, relaunch or quit anything.

/// One GET of the latest-release endpoint.
protocol ReleaseFetching: Sendable {
    /// The reply, or `nil` when there was none — offline, a timeout, a
    /// cancelled request. Never throws: every failure is a value Core
    /// classifies.
    func fetch(headers: [String: String]) async -> HTTPReply?
}

/// The real request, to `UpdateEndpoint.latestRelease`.
struct GitHubReleaseFetcher: ReleaseFetching {
    /// An ephemeral session with no cache: `URLCache` would answer a
    /// conditional request itself and turn GitHub's 304 into a 200 built
    /// from its own copy, and the ETag is something this app keeps on
    /// purpose, in the preferences domain, where `defaults read` shows it.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    func fetch(headers: [String: String]) async -> HTTPReply? {
        var request = URLRequest(url: UpdateEndpoint.latestRelease)
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        guard let (data, response) = try? await Self.session.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        return HTTPReply(
            status: http.statusCode,
            body: data,
            etag: http.value(forHTTPHeaderField: "ETag"),
            rateLimitRemaining: http.value(forHTTPHeaderField: "X-RateLimit-Remaining")
        )
    }
}

/// What a delegate a test builds asks: nobody. Reads as offline.
struct InertReleaseFetcher: ReleaseFetching {
    func fetch(headers: [String: String]) async -> HTTPReply? { nil }
}

/// Downloads one file to a path of the caller's choosing.
protocol UpdateDownloading: Sendable {
    func download(_ url: URL, to destination: URL) async throws
}

/// A `URLSession` download task, which streams to disk rather than
/// holding the archive in memory, then moved to `destination`.
struct URLSessionUpdateDownloader: UpdateDownloading {
    struct BadStatus: Error { let status: Int }

    func download(_ url: URL, to destination: URL) async throws {
        var request = URLRequest(url: url)
        request.setValue(UpdateEndpoint.userAgent(version: CoreInfo.version), forHTTPHeaderField: "User-Agent")
        let (file, response) = try await GitHubReleaseFetcher.session.download(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: file)
            throw BadStatus(status: http.statusCode)
        }
        try FileManager.default.moveItem(at: file, to: destination)
    }
}

/// Runs a command-line tool by absolute path and reports its exit status.
protocol UpdateToolRunning: Sendable {
    func run(_ tool: String, _ arguments: [String]) async -> Int32
}

/// `Process`, with its output discarded — the exit status is the whole
/// answer for `tar`, `codesign` and `xattr`, and an unread pipe that fills
/// would stall the tool forever.
struct ProcessToolRunner: UpdateToolRunning {
    func run(_ tool: String, _ arguments: [String]) async -> Int32 {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: -1)
            }
        }
    }
}

/// The file moves of the swap, so a test can make one fail.
protocol UpdateFileOperating: Sendable {
    func moveItem(at source: URL, to destination: URL) throws
    func removeItem(at url: URL) throws
    func fileExists(at url: URL) -> Bool
}

struct SystemFileOperations: UpdateFileOperating {
    func moveItem(at source: URL, to destination: URL) throws {
        try FileManager.default.moveItem(at: source, to: destination)
    }

    func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}

/// Downloads, verifies and swaps in one release.
protocol UpdateInstalling: Sendable {
    func install(
        _ release: Release, over bundle: URL, progress: @escaping @Sendable (UpdatePhase) async -> Void
    ) async throws(UpdateInstallFailure)
}

/// What a delegate a test builds installs: nothing.
struct InertUpdateInstaller: UpdateInstalling {
    func install(
        _ release: Release, over bundle: URL, progress: @escaping @Sendable (UpdatePhase) async -> Void
    ) async throws(UpdateInstallFailure) {
        throw .downloadFailed
    }
}

/// The detached helper that opens the new copy once this one has quit.
enum UpdateRelaunch {
    /// `/bin/sh` arguments: wait a second, then until `pid` has exited (at
    /// most ten seconds more), then open the bundle.
    ///
    /// Waiting for the pid rather than trusting the second: `open` on an
    /// app whose bundle identifier is still running activates the running
    /// copy instead of launching the new one, so an old copy slow to quit
    /// would swallow the relaunch. The path and pid go in as positional
    /// parameters, never spliced into the script, so a path with a space or
    /// a quote in it reaches `open` exactly as it is.
    static func arguments(bundlePath: String, waitingFor pid: Int32, opener: String = "/usr/bin/open") -> [String] {
        ["-c", script, bundlePath, String(pid), opener]
    }

    /// `$0` the bundle, `$1` the pid to outlast, `$2` the opener.
    static let script = "sleep 1; i=0; while kill -0 $1 2>/dev/null && [ $i -lt 50 ]; do sleep 0.2; i=$((i+1)); done; exec \"$2\" \"$0\""

    /// Spawns the helper and returns at once. It is not waited on: it has
    /// to outlive this process, which is about to terminate.
    static func spawn(bundle: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = arguments(bundlePath: bundle.path, waitingFor: ProcessInfo.processInfo.processIdentifier)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
