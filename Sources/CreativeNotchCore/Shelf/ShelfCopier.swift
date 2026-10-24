import Foundation

/// How the shelf copies a dropped file, and how it asks whether one fits.
///
/// A value of two closures rather than calls straight to `FileManager`, so a
/// test can decide when each copy finishes -- and whether it fails --
/// without copying anything large or sleeping. The app always uses
/// `.system`.
public struct ShelfCopier: Sendable {

    /// Copies `source` to `destination`, a hidden temporary name inside the
    /// shelf directory. Called off the main actor; must not touch the store.
    public var copy: @Sendable (_ source: URL, _ destination: URL) async throws -> Void

    /// Bytes free for an important write on the volume holding `directory`,
    /// or `nil` when the volume will not say -- which skips the check
    /// rather than refusing every drop.
    public var availableCapacity: @Sendable (_ directory: URL) -> Int64?

    public init(
        copy: @escaping @Sendable (URL, URL) async throws -> Void,
        availableCapacity: @escaping @Sendable (URL) -> Int64?
    ) {
        self.copy = copy
        self.availableCapacity = availableCapacity
    }

    /// `FileManager.copyItem` on a detached task, so a multi-gigabyte copy
    /// from another volume holds a background thread instead of the main
    /// one. Detached, not a plain `Task`, which would inherit the main actor
    /// from the store that starts it.
    ///
    /// Not cancellable part-way: `copyItem` has no cancellation, and nothing
    /// cancels a copy anyway. A quit abandons it, and the partial is
    /// deleted at the next launch.
    public static let system = ShelfCopier(
        copy: { source, destination in
            try await Task.detached(priority: .utility) {
                try FileManager.default.copyItem(at: source, to: destination)
            }.value
        },
        availableCapacity: { directory in
            let values = try? directory.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            return values?.volumeAvailableCapacityForImportantUsage
        }
    )
}
