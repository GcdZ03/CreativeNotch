import Foundation

/// A `FileManager` whose Trash is a temporary directory, for the wiring
/// suites that lower a shelf limit through the delegate.
///
/// `trashItem` is the one call that would reach the user's real `~/.Trash`;
/// here it moves into a directory the test owns. A copy of the Core suite's
/// helper rather than a shared one: the two test targets do not depend on
/// each other, and a test-only type does not belong in a shipping module.
final class SandboxTrash: FileManager, @unchecked Sendable {
    let root: URL
    private let bin: URL
    private(set) var trashed: [URL] = []

    override init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CreativeNotchSandboxTrash-\(UUID().uuidString)")
        bin = root.appendingPathComponent("Trash")
        super.init()
        try? createDirectory(at: bin, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    override func trashItem(at url: URL, resultingItemURL outResultingURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
        let destination = bin.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
        try moveItem(at: url, to: destination)
        trashed.append(destination)
        outResultingURL?.pointee = destination as NSURL
    }
}
