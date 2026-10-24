import CryptoKit
import Foundation
import CreativeNotchCore
@testable import CreativeNotchUI

/// Stand-ins for everything the updater reaches outside the process
/// (2026-10-24). None of them touches the network, runs a real `codesign`,
/// or goes near `/Applications`; the swap they allow runs on a fake bundle
/// in a temporary folder.
enum UpdateFakes {

    static let notes = URL(string: "https://github.com/GcdZ03/CreativeNotch/releases/tag/v0.13.0")!

    static func release(_ tag: String = "v0.13.0", installable: Bool = true) -> Release {
        Release(
            tag: tag,
            notesURL: notes,
            archiveURL: installable ? URL(string: "https://github.com/GcdZ03/CreativeNotch/releases/download/\(tag)/CreativeNotch-\(tag).tar.gz") : nil,
            checksumURL: installable ? URL(string: "https://github.com/GcdZ03/CreativeNotch/releases/download/\(tag)/CreativeNotch-\(tag).tar.gz.sha256") : nil
        )
    }

    /// A `releases/latest` body for `tag`, with both assets.
    static func body(_ tag: String = "v0.13.0") -> Data {
        Data(#"""
        {"tag_name": "\#(tag)", "html_url": "https://github.com/GcdZ03/CreativeNotch/releases/tag/\#(tag)",
         "assets": [
          {"name": "CreativeNotch-\#(tag).tar.gz", "browser_download_url": "https://github.com/GcdZ03/CreativeNotch/releases/download/\#(tag)/CreativeNotch-\#(tag).tar.gz"},
          {"name": "CreativeNotch-\#(tag).tar.gz.sha256", "browser_download_url": "https://github.com/GcdZ03/CreativeNotch/releases/download/\#(tag)/CreativeNotch-\#(tag).tar.gz.sha256"}]}
        """#.utf8)
    }

    static func temporaryDirectory(_ label: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CreativeNotch-\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A minimal app bundle: an Info.plist with a version, and a marker file
    /// saying which copy it is.
    static func makeBundle(at url: URL, version: String, marker: String) throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleShortVersionString": version], format: .xml, options: 0
        )
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        try Data(marker.utf8).write(to: contents.appendingPathComponent("marker"))
    }

    static func marker(of bundle: URL) -> String? {
        (try? Data(contentsOf: bundle.appendingPathComponent("Contents/marker"))).map { String(decoding: $0, as: UTF8.self) }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Replies in order, recording every request's headers.
actor FakeReleaseFetcher: ReleaseFetching {
    private var replies: [HTTPReply?]
    private(set) var requests: [[String: String]] = []

    init(_ replies: [HTTPReply?]) { self.replies = replies }

    func fetch(headers: [String: String]) async -> HTTPReply? {
        requests.append(headers)
        return replies.isEmpty ? nil : replies.removeFirst()
    }

    var count: Int { requests.count }

    static func ok(_ tag: String = "v0.13.0", etag: String? = #"W/"1""#) -> HTTPReply {
        HTTPReply(status: 200, body: UpdateFakes.body(tag), etag: etag, rateLimitRemaining: "59")
    }

    static let notModified = HTTPReply(status: 304, body: Data(), etag: #"W/"1""#, rateLimitRemaining: "59")
    static let rateLimited = HTTPReply(status: 403, body: Data(), etag: nil, rateLimitRemaining: "0")
}

/// Writes canned bytes for each URL, or fails.
struct FakeDownloader: UpdateDownloading {
    let files: [URL: Data]

    struct Missing: Error {}

    func download(_ url: URL, to destination: URL) async throws {
        guard let data = files[url] else { throw Missing() }
        try data.write(to: destination)
    }
}

/// Plays `tar` by building a bundle in its `-C` folder, answers `codesign`
/// as told, and records every call.
final class FakeToolRunner: UpdateToolRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(String, [String])] = []

    /// The version the "extracted" app claims; `nil` extracts nothing.
    let extractedVersion: String?
    let tarStatus: Int32
    let codesignStatus: Int32

    init(extractedVersion: String? = "0.13.0", tarStatus: Int32 = 0, codesignStatus: Int32 = 0) {
        self.extractedVersion = extractedVersion
        self.tarStatus = tarStatus
        self.codesignStatus = codesignStatus
    }

    var calls: [(String, [String])] { lock.withLock { _calls } }
    var tools: [String] { calls.map(\.0) }

    func run(_ tool: String, _ arguments: [String]) async -> Int32 {
        lock.withLock { _calls.append((tool, arguments)) }
        switch tool {
        case "/usr/bin/tar":
            guard tarStatus == 0 else { return tarStatus }
            if let extractedVersion, let index = arguments.firstIndex(of: "-C") {
                let folder = URL(fileURLWithPath: arguments[index + 1])
                try? UpdateFakes.makeBundle(
                    at: folder.appendingPathComponent("CreativeNotch.app"), version: extractedVersion, marker: "new"
                )
            }
            return 0
        case "/usr/bin/codesign":
            return codesignStatus
        default:
            return 0
        }
    }
}

/// The real file operations, refusing the next `n` moves onto each named
/// destination.
final class FailingFileOperations: UpdateFileOperating, @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: [String: Int]

    init(failing destinations: [URL: Int]) {
        remaining = Dictionary(uniqueKeysWithValues: destinations.map { ($0.key.standardizedFileURL.path, $0.value) })
    }

    struct Refused: Error {}

    func moveItem(at source: URL, to destination: URL) throws {
        let refuse = lock.withLock { () -> Bool in
            let key = destination.standardizedFileURL.path
            guard let count = remaining[key], count > 0 else { return false }
            remaining[key] = count - 1
            return true
        }
        if refuse { throw Refused() }
        try FileManager.default.moveItem(at: source, to: destination)
    }

    func removeItem(at url: URL) throws { try FileManager.default.removeItem(at: url) }
    func fileExists(at url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
}

/// Runs the real pipeline's steps in order, reporting each phase, then
/// succeeds or fails as told. Reads the controller's status after each
/// phase through `probe`.
actor FakeInstaller: UpdateInstalling {
    let failure: UpdateInstallFailure?
    private(set) var installs: [(Release, URL)] = []
    private(set) var observed: [UpdateStatus] = []
    private var probe: (@Sendable () async -> UpdateStatus)?

    init(failure: UpdateInstallFailure? = nil) { self.failure = failure }

    func setProbe(_ probe: @escaping @Sendable () async -> UpdateStatus) { self.probe = probe }

    func install(
        _ release: Release, over bundle: URL, progress: @escaping @Sendable (UpdatePhase) async -> Void
    ) async throws(UpdateInstallFailure) {
        installs.append((release, bundle))
        for phase in [UpdatePhase.downloading, .verifying, .installing] {
            await progress(phase)
            if let probe { observed.append(await probe()) }
            if let failure, phase == .verifying { throw failure }
        }
    }
}
