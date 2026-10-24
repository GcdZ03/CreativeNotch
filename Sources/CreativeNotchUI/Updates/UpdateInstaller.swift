import CryptoKit
import Foundation
import CreativeNotchCore

/// "Update Now", end to end (2026-10-24): download, verify, swap.
///
/// The steps and their safety are `Scripts/install.sh`'s, which
/// `Scripts/tests/install-test.sh` covers — with two additions the script
/// cannot make, because the app has more to check against: the archive's
/// SHA-256 against the release's `.sha256`, and the unpacked app's version
/// against the release's tag. And one subtraction: no `sudo`, ever (see
/// `UpdateInstallEligibility.needsAdmin`).
///
/// **Nothing half-installed, on any failure.** Everything up to the swap
/// happens in a temporary folder that is removed however the call ends.
/// The swap moves the running copy aside rather than deleting it, and puts
/// it back if the new one will not go in; the one failure that leaves
/// anything behind — the old copy cannot be put back either — says where it
/// is, as `install.sh` does.
///
/// A nonisolated `async` method, so it runs off the main actor: hashing a
/// few megabytes and waiting on `tar` must not stall the notch.
struct UpdateInstaller: UpdateInstalling {
    let downloader: any UpdateDownloading
    let tools: any UpdateToolRunning
    let files: any UpdateFileOperating
    /// Where the download folder is made. The system's temporary folder in
    /// the app; a test's own folder in the tests.
    let temporaryRoot: URL
    /// Names the swap's hidden folders, like `install.sh`'s `$$`.
    let pid: Int32

    /// The name `release.yml` packs the app under (`tar -C dist CreativeNotch.app`).
    static let appName = "CreativeNotch.app"

    /// The real seams.
    static func system() -> UpdateInstaller {
        UpdateInstaller(
            downloader: URLSessionUpdateDownloader(),
            tools: ProcessToolRunner(),
            files: SystemFileOperations(),
            temporaryRoot: FileManager.default.temporaryDirectory,
            pid: ProcessInfo.processInfo.processIdentifier
        )
    }

    func install(
        _ release: Release, over bundle: URL, progress: @escaping @Sendable (UpdatePhase) async -> Void
    ) async throws(UpdateInstallFailure) {
        guard let archiveURL = release.archiveURL, let checksumURL = release.checksumURL else {
            throw .notInstallable
        }
        let work = temporaryRoot.appendingPathComponent("CreativeNotchUpdate-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        } catch {
            throw .downloadFailed
        }
        defer { try? FileManager.default.removeItem(at: work) }

        // 1. Download both, before trusting either.
        await progress(.downloading)
        let archive = work.appendingPathComponent(release.archiveName)
        let checksum = work.appendingPathComponent(release.checksumName)
        do {
            try await downloader.download(archiveURL, to: archive)
            try await downloader.download(checksumURL, to: checksum)
        } catch {
            throw .downloadFailed
        }

        // 2. The checksum, before the archive is so much as unpacked.
        await progress(.verifying)
        guard let text = try? String(contentsOf: checksum, encoding: .utf8),
              let expected = ReleaseChecksum.expected(in: text, for: release.archiveName) else {
            throw .checksumUnreadable
        }
        guard let digest = try? Self.sha256(of: archive), ReleaseChecksum.matches(expected, digest: digest) else {
            throw .checksumMismatch
        }

        // 3. Unpack, then the signature and the version of what came out.
        let extracted = work.appendingPathComponent("extracted", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        } catch {
            throw .extractFailed
        }
        guard await tools.run("/usr/bin/tar", ["-xzf", archive.path, "-C", extracted.path]) == 0 else {
            throw .extractFailed
        }
        let app = extracted.appendingPathComponent(Self.appName, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: app.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw .appMissing
        }
        guard await tools.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) == 0 else {
            throw .signatureInvalid
        }
        let version = Self.shortVersion(of: app)
        guard UpdateBundleCheck.matches(bundleVersion: version, tag: release.tag) else {
            throw .versionMismatch(found: version)
        }

        // 4. The swap.
        await progress(.installing)
        try swap(app, into: UpdateSwapPaths(bundle: bundle, pid: pid))
        // As `install.sh` does, and as harmless to skip: a download through
        // `URLSession` is not quarantined, but an archive unpacked from one
        // that was would carry the flag onto every file.
        _ = await tools.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", bundle.path])
    }

    /// Stages the new copy beside the bundle, moves the running one aside,
    /// moves the new one in — and on failure, puts everything back.
    ///
    /// Staging first is the one step `install.sh` does not take: the
    /// download folder may be on another volume, where a move is a copy
    /// that can fail halfway. Staged beside the bundle, the two moves that
    /// matter are renames on one volume, so the window in which neither
    /// copy is at the bundle's path is two renames wide.
    private func swap(_ app: URL, into paths: UpdateSwapPaths) throws(UpdateInstallFailure) {
        if files.fileExists(at: paths.staging) { try? files.removeItem(at: paths.staging) }
        do {
            try files.moveItem(at: app, to: paths.staging)
        } catch {
            try? files.removeItem(at: paths.staging)
            throw .moveFailed
        }

        // A backup left by an attempt that died with this same pid.
        if files.fileExists(at: paths.backup) { try? files.removeItem(at: paths.backup) }
        do {
            try files.moveItem(at: paths.bundle, to: paths.backup)
        } catch {
            try? files.removeItem(at: paths.staging)
            throw .moveFailed
        }

        do {
            try files.moveItem(at: paths.staging, to: paths.bundle)
        } catch {
            // A failed move can leave a partial copy at the destination;
            // moving the backup onto it would nest it inside instead.
            if files.fileExists(at: paths.bundle) { try? files.removeItem(at: paths.bundle) }
            try? files.removeItem(at: paths.staging)
            do {
                try files.moveItem(at: paths.backup, to: paths.bundle)
            } catch {
                throw .restoreFailed(backupPath: paths.backup.path)
            }
            throw .moveFailed
        }

        // The running process keeps its open files; the old bundle's
        // directory entries go now, as `install.sh`'s `rm -rf "$BACKUP"`.
        try? files.removeItem(at: paths.backup)
    }

    /// The unpacked app's `CFBundleShortVersionString`, read from the file
    /// rather than through `Bundle`, which caches by path.
    static func shortVersion(of app: URL) -> String? {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let info = object as? [String: Any] else { return nil }
        return info["CFBundleShortVersionString"] as? String
    }

    /// The file's SHA-256 as lowercase hex, read a megabyte at a time.
    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
