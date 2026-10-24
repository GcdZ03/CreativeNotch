import Foundation
import CreativeNotchCore

/// A stand-in for the user's Trash, shared by every test in this target.
///
/// Every store and delegate a test builds is handed this, so clearing,
/// evicting and purging move scratch files into a temporary folder and
/// never into ~/.Trash.
enum TestTrash {
    static let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("test-trash-\(UUID().uuidString)", isDirectory: true)

    static let shelf: ShelfTrash = .folder(folder)
}
