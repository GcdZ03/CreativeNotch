import Foundation
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// "Update Now"'s pipeline, run for real against a fake bundle in a
/// temporary folder (2026-10-24): download, checksum, unpack, signature,
/// version, swap — and, on every failure, the running copy left exactly
/// where it was. The safety mirrors `Scripts/install.sh`, which
/// `Scripts/tests/install-test.sh` covers the same way.
///
/// Nothing here touches the network, a real `codesign`, or `/Applications`:
/// the downloader and the tools are fakes, and the "running app" is a
/// folder made for each test.
struct UpdateInstallerTests {

    let root = UpdateFakes.temporaryDirectory("installer")
    var installs: URL { root.appendingPathComponent("Applications", isDirectory: true) }
    var bundle: URL { installs.appendingPathComponent("CreativeNotch.app", isDirectory: true) }
    var scratch: URL { root.appendingPathComponent("tmp", isDirectory: true) }

    let release = UpdateFakes.release()
    let archive = Data("pretend this is a tar.gz".utf8)

    init() throws {
        try FileManager.default.createDirectory(at: installs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try UpdateFakes.makeBundle(at: bundle, version: "0.12.0", marker: "old")
    }

    private func downloader(checksum: String? = nil, archive: Data? = nil) -> FakeDownloader {
        let bytes = archive ?? self.archive
        let line = checksum ?? "\(UpdateFakes.sha256(bytes))  \(release.archiveName)\n"
        return FakeDownloader(files: [
            release.archiveURL!: bytes,
            release.checksumURL!: Data(line.utf8),
        ])
    }

    private func installer(
        downloader: (any UpdateDownloading)? = nil,
        tools: any UpdateToolRunning = FakeToolRunner(),
        files: any UpdateFileOperating = SystemFileOperations()
    ) -> UpdateInstaller {
        UpdateInstaller(
            downloader: downloader ?? self.downloader(),
            tools: tools, files: files, temporaryRoot: scratch, pid: 4242
        )
    }

    private func run(_ installer: UpdateInstaller) async -> (UpdateInstallFailure?, [UpdatePhase]) {
        let phases = PhaseLog()
        do throws(UpdateInstallFailure) {
            try await installer.install(release, over: bundle) { await phases.append($0) }
            return (nil, await phases.all)
        } catch {
            return (error, await phases.all)
        }
    }

    private var leftovers: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: installs.path)) ?? []).sorted()
    }

    private var scratchIsEmpty: Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: scratch.path)) ?? []).isEmpty
    }

    // MARK: - Success

    @Test func replacesTheBundleInPlace() async {
        let tools = FakeToolRunner()
        let (failure, phases) = await run(installer(tools: tools))
        #expect(failure == nil)
        #expect(phases == [.downloading, .verifying, .installing])
        #expect(UpdateFakes.marker(of: bundle) == "new")
        // No backup, no staging copy, nothing else beside it.
        #expect(leftovers == ["CreativeNotch.app"])
        #expect(scratchIsEmpty, "the download folder was left behind")
    }

    @Test func runsTheToolsWithInstallShsArguments() async throws {
        let tools = FakeToolRunner()
        _ = await run(installer(tools: tools))
        #expect(tools.tools == ["/usr/bin/tar", "/usr/bin/codesign", "/usr/bin/xattr"])
        let tar = try #require(tools.calls.first { $0.0 == "/usr/bin/tar" }?.1)
        #expect(tar.first == "-xzf")
        #expect(tar[1].hasSuffix(release.archiveName))
        #expect(tar[2] == "-C")
        let codesign = try #require(tools.calls.first { $0.0 == "/usr/bin/codesign" }?.1)
        #expect(codesign.prefix(3) == ["--verify", "--deep", "--strict"])
        #expect(codesign.last?.hasSuffix("CreativeNotch.app") == true)
        // The quarantine flag is cleared on the copy now in place.
        let xattr = try #require(tools.calls.first { $0.0 == "/usr/bin/xattr" }?.1)
        #expect(xattr == ["-dr", "com.apple.quarantine", bundle.path])
    }

    // MARK: - Refusals before anything moves

    @Test func aChecksumMismatchIsRefusedBeforeUnpacking() async {
        let tools = FakeToolRunner()
        let wrong = String(repeating: "0", count: 64)
        let (failure, phases) = await run(installer(downloader: downloader(checksum: "\(wrong)  \(release.archiveName)"), tools: tools))
        #expect(failure == .checksumMismatch)
        #expect(phases == [.downloading, .verifying])
        #expect(tools.calls.isEmpty, "a mismatched archive was handed to tar")
        #expect(UpdateFakes.marker(of: bundle) == "old")
        #expect(leftovers == ["CreativeNotch.app"])
        #expect(scratchIsEmpty)
    }

    @Test func anUnreadableChecksumIsRefused() async {
        let (failure, _) = await run(installer(downloader: downloader(checksum: "not a checksum")))
        #expect(failure == .checksumUnreadable)
        #expect(UpdateFakes.marker(of: bundle) == "old")
    }

    @Test func aFailedDownloadIsReported() async {
        let (failure, phases) = await run(installer(downloader: FakeDownloader(files: [:])))
        #expect(failure == .downloadFailed)
        #expect(phases == [.downloading])
        #expect(UpdateFakes.marker(of: bundle) == "old")
        #expect(scratchIsEmpty)
    }

    @Test func aReleaseWithoutAssetsIsNotInstalled() async {
        let bare = UpdateFakes.release(installable: false)
        do throws(UpdateInstallFailure) {
            try await installer().install(bare, over: bundle) { _ in }
            Issue.record("installed a release with no assets")
        } catch {
            #expect(error == .notInstallable)
        }
    }

    @Test func aFailedExtractionIsReported() async {
        let (failure, _) = await run(installer(tools: FakeToolRunner(tarStatus: 2)))
        #expect(failure == .extractFailed)
        #expect(UpdateFakes.marker(of: bundle) == "old")
        #expect(scratchIsEmpty)
    }

    @Test func anArchiveWithoutTheAppIsRefused() async {
        let (failure, _) = await run(installer(tools: FakeToolRunner(extractedVersion: nil)))
        #expect(failure == .appMissing)
        #expect(UpdateFakes.marker(of: bundle) == "old")
    }

    @Test func aBadSignatureIsRefused() async {
        let tools = FakeToolRunner(codesignStatus: 1)
        let (failure, phases) = await run(installer(tools: tools))
        #expect(failure == .signatureInvalid)
        #expect(!phases.contains(.installing))
        #expect(!tools.tools.contains("/usr/bin/xattr"))
        #expect(UpdateFakes.marker(of: bundle) == "old")
        #expect(leftovers == ["CreativeNotch.app"])
        #expect(scratchIsEmpty)
    }

    @Test func theWrongVersionIsRefused() async {
        let (failure, _) = await run(installer(tools: FakeToolRunner(extractedVersion: "0.12.5")))
        #expect(failure == .versionMismatch(found: "0.12.5"))
        #expect(UpdateFakes.marker(of: bundle) == "old")
    }

    // MARK: - The swap failing

    /// The new copy cannot be moved into place: the old one goes back, and
    /// nothing half-installed is left beside it.
    @Test func aFailedMoveRestoresTheRunningCopy() async {
        let files = FailingFileOperations(failing: [bundle: 1])
        let (failure, _) = await run(installer(files: files))
        #expect(failure == .moveFailed)
        #expect(UpdateFakes.marker(of: bundle) == "old")
        #expect(leftovers == ["CreativeNotch.app"])
        #expect(scratchIsEmpty)
    }

    /// The running copy cannot even be moved aside: nothing changed.
    @Test func aRefusedBackupChangesNothing() async {
        let paths = UpdateSwapPaths(bundle: bundle, pid: 4242)
        let (failure, _) = await run(installer(files: FailingFileOperations(failing: [paths.backup: 1])))
        #expect(failure == .moveFailed)
        #expect(UpdateFakes.marker(of: bundle) == "old")
        #expect(leftovers == ["CreativeNotch.app"])
    }

    /// The worst case: the new copy will not go in and the old one will not
    /// go back. The failure says where the old one is, and it is there.
    @Test func aFailedRestoreSaysWhereThePreviousCopyIs() async {
        let paths = UpdateSwapPaths(bundle: bundle, pid: 4242)
        // Every move onto the bundle's path fails — the new copy's and the
        // restore's alike.
        let (failure, _) = await run(installer(files: FailingFileOperations(failing: [bundle: 2])))
        #expect(failure == .restoreFailed(backupPath: paths.backup.path))
        #expect(UpdateFakes.marker(of: paths.backup) == "old")
    }

    /// A backup left by a crashed attempt with the same pid does not block
    /// the next one.
    @Test func aStaleBackupIsReplaced() async throws {
        let paths = UpdateSwapPaths(bundle: bundle, pid: 4242)
        try UpdateFakes.makeBundle(at: paths.backup, version: "0.1.0", marker: "stale")
        let (failure, _) = await run(installer())
        #expect(failure == nil)
        #expect(UpdateFakes.marker(of: bundle) == "new")
        #expect(leftovers == ["CreativeNotch.app"])
    }

    // MARK: - Real tools, on temporary files only

    /// The real `tar`, on an archive made here, through the real runner —
    /// only `codesign` is answered by the fake, since the fake bundle is not
    /// signed. Proves the flags the pipeline passes actually unpack the
    /// layout the release workflow packs (`tar -czf … -C dist CreativeNotch.app`).
    @Test func theRealTarUnpacksTheReleaseLayout() async throws {
        let staging = root.appendingPathComponent("dist", isDirectory: true)
        try UpdateFakes.makeBundle(at: staging.appendingPathComponent("CreativeNotch.app"), version: "0.13.0", marker: "packed")
        let packed = root.appendingPathComponent(release.archiveName)
        let status = await ProcessToolRunner().run("/usr/bin/tar", ["-czf", packed.path, "-C", staging.path, "CreativeNotch.app"])
        #expect(status == 0)
        let bytes = try Data(contentsOf: packed)

        let tools = TarRealCodesignFake()
        let (failure, _) = await run(installer(downloader: downloader(archive: bytes), tools: tools))
        #expect(failure == nil)
        #expect(UpdateFakes.marker(of: bundle) == "packed")
    }

    @Test func theRealRunnerReportsExitStatus() async {
        #expect(await ProcessToolRunner().run("/usr/bin/true", []) == 0)
        #expect(await ProcessToolRunner().run("/usr/bin/false", []) != 0)
        #expect(await ProcessToolRunner().run("/nonexistent/tool", []) != 0)
    }

    /// The digest is computed in chunks; it must still be the digest.
    @Test func theFileDigestIsSHA256() throws {
        let file = root.appendingPathComponent("abc")
        try Data("abc".utf8).write(to: file)
        #expect(try UpdateInstaller.sha256(of: file)
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let big = root.appendingPathComponent("big")
        let data = Data((0..<3_000_000).map { UInt8($0 % 251) })
        try data.write(to: big)
        #expect(try UpdateInstaller.sha256(of: big) == UpdateFakes.sha256(data))
    }
}

/// Collects phases across the installer's hops.
actor PhaseLog {
    private(set) var all: [UpdatePhase] = []
    func append(_ phase: UpdatePhase) { all.append(phase) }
}

/// The real runner for everything but `codesign` and `xattr`.
struct TarRealCodesignFake: UpdateToolRunning {
    func run(_ tool: String, _ arguments: [String]) async -> Int32 {
        guard tool == "/usr/bin/tar" else { return 0 }
        return await ProcessToolRunner().run(tool, arguments)
    }
}
