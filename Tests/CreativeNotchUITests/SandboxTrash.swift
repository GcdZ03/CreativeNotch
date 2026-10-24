import Foundation
import CreativeNotchCore

/// A Trash that is a temporary directory and counts what reaches it, for
/// the wiring suites that lower a shelf limit through the delegate.
///
/// Handed to the delegate as `shelf`, the `ShelfTrash` every eviction and
/// purge goes through, so nothing reaches the user's real `~/.Trash`. A copy
/// of the Core suite's helper rather than a shared one: the two test targets
/// do not depend on each other, and a test-only type does not belong in a
/// shipping module.
final class SandboxTrash: @unchecked Sendable {
    let root: URL
    private let bin: URL
    private(set) var trashed: [URL] = []

    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CreativeNotchSandboxTrash-\(UUID().uuidString)")
        bin = root.appendingPathComponent("Trash")
        try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    /// The store-facing Trash. Holds this sandbox for as long as the store
    /// that uses it lives.
    var shelf: ShelfTrash {
        ShelfTrash { url in try self.move(url) }
    }

    private func move(_ url: URL) throws -> URL {
        let destination = bin.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
        try FileManager.default.moveItem(at: url, to: destination)
        trashed.append(destination)
        return destination
    }
}
