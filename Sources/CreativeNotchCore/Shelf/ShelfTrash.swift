import Foundation

/// Where the shelf moves an owned file it lets go of.
///
/// A value rather than a call straight to `FileManager.trashItem`, so tests
/// can send what they clear, evict and purge to a temporary folder instead
/// of the user's real Trash -- which a test run would otherwise fill with
/// its scratch files, and which a sandboxed verifier cannot even read to
/// check. Only the real launch uses `.system` (`AppDelegate.configureForRealLaunch`).
public struct ShelfTrash: Sendable {

    /// Moves the file at the URL out of the shelf and returns where it went,
    /// which is what lets a clear be undone; `nil` if the destination is
    /// unknown.
    public var move: @Sendable (URL) throws -> URL?

    /// Whether this is `.system`, the user's real Trash.
    ///
    /// Exists so a test can ask which Trash a delegate holds *without
    /// calling it*: the only behavioural way to tell `.system` apart is to
    /// move a file with it, which is the very thing the question guards.
    public let isSystem: Bool

    public init(move: @escaping @Sendable (URL) throws -> URL?) {
        self.init(move: move, isSystem: false)
    }

    private init(move: @escaping @Sendable (URL) throws -> URL?, isSystem: Bool) {
        self.move = move
        self.isSystem = isSystem
    }

    /// The user's Trash, through `FileManager.trashItem`.
    public static let system = ShelfTrash(move: { url in
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return resulting as URL?
    }, isSystem: true)

    /// A stand-in Trash: each file is moved into its own fresh subfolder of
    /// `directory`, so two files of the same name never collide, and the
    /// returned URL can be moved back as one from the real Trash can.
    public static func folder(_ directory: URL) -> ShelfTrash {
        ShelfTrash { url in
            let slot = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: slot, withIntermediateDirectories: true)
            let destination = slot.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        }
    }
}
