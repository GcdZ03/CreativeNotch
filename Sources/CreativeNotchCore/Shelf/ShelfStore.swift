import Foundation
import Observation

/// The shelf's contents and every file operation on them.
///
/// Lives in `CreativeNotchCore` because `FileManager` is Foundation, not
/// AppKit — which puts the code that can destroy a file in the target that
/// runs headlessly in CI.
///
/// `@MainActor` because every caller is: the drop target, the view, and the
/// menu bar item. File I/O on the main actor is acceptable at this scale —
/// twenty items, and disk is touched only on add or remove.
///
/// The known cost is `add(.file)`: a same-volume copy is an APFS clone and
/// instant, but a multi-gigabyte drop from another volume holds the main
/// thread for the length of the copy. It stays synchronous on purpose.
/// `performDragOperation` must answer accepted-or-refused before it
/// returns, and spec section 9 says a drop that cannot be stored is
/// refused — an off-main copy could only accept optimistically and fail
/// later, and concurrent copies would race `uniqueURL` for the same name.
/// Moving it off-main means a pending-item state in the store, not a
/// `Task` around the copy.
///
/// `@Observable` so a view reading `items` is told when they change.
/// Without it the shelf only appeared to work: every drop is followed by
/// `state.transition(to: .open(.shelf))`, and `AppState` *is* observable,
/// so the view was rebuilt by the state change rather than by the store.
/// "Clear Shelf" from the menu bar performs no transition, and left
/// thumbnails on screen for files already in the Trash.
///
/// `Observation` is not a UI framework, so `CorePurityTests` is unaffected.
@MainActor
@Observable
public final class ShelfStore {

    public static let capacity = 20
    public static let maxAge: TimeInterval = 7 * 24 * 3600

    /// Newest first.
    public private(set) var items: [ShelfItem] = []

    private let directory: URL
    private let fileManager: FileManager

    public init(directory: URL, fileManager: FileManager = .default) throws {
        self.directory = directory
        self.fileManager = fileManager
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        items = Self.load(from: directory, fileManager: fileManager)
    }

    /// Rebuilds the list from what is actually on disk.
    ///
    /// The directory is the source of truth: there is no sidecar index to
    /// fall out of step with it, and a file removed from underneath us
    /// simply stops appearing. `addedAt` comes from the file's creation
    /// date, which is what the 7-day purge measures against -- and which
    /// `add` stamps with the drop time, because a copy otherwise keeps the
    /// *source's* creation date.
    private static func load(from directory: URL, fileManager: FileManager) -> [ShelfItem] {
        let urls = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return urls.compactMap { url -> ShelfItem? in
            guard let created = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
            else { return nil }
            return ShelfItem(
                id: UUID(),
                url: url,
                displayName: url.lastPathComponent,
                addedAt: created
            )
        }
        .sorted { $0.addedAt > $1.addedAt }
    }

    @discardableResult
    public func add(_ payload: DropPayload, now: Date) throws -> ShelfItem {
        let destination = uniqueURL(for: payload.suggestedName)

        switch payload {
        case .file(let source):
            try fileManager.copyItem(at: source, to: destination)
        case .text(let string):
            try string.write(to: destination, atomically: true, encoding: .utf8)
        case .image(let data, _):
            try data.write(to: destination, options: .atomic)
        }

        // `copyItem` keeps the source's creation date, and `load` reads
        // `addedAt` back from it. Unstamped, a file made a month ago and
        // dropped this morning reloads as a month old and the launch purge
        // trashes it. The creation date is the record of the drop time --
        // no sidecar index -- so it is set here, for every payload kind.
        //
        // `try?` because the copy has already landed: failing the drop now
        // would leave an unlisted file that reappears at the next launch,
        // which is worse than an age that is merely wrong.
        try? fileManager.setAttributes([.creationDate: now], ofItemAtPath: destination.path)

        let item = ShelfItem(
            id: UUID(),
            url: destination,
            displayName: destination.lastPathComponent,
            addedAt: now
        )
        items.insert(item, at: 0)
        try evictBeyondCapacity()
        try purge(now: now)
        return item
    }

    /// Puts a file on the shelf **without copying or owning it**.
    ///
    /// For things the app itself created somewhere the user cares about -- a
    /// camera capture in `~/Pictures`. The shelf shows it and lets it be
    /// dragged out; it never moves, copies or trashes it.
    ///
    /// It still counts toward the capacity limit and still expires from the
    /// list, because the shelf is a view of recent things and a reference that
    /// never aged out would crowd real drops off it. What expiry does *not* do
    /// is touch the file.
    @discardableResult
    public func addReference(to url: URL, now: Date) throws -> ShelfItem {
        let item = ShelfItem(
            id: UUID(),
            url: url,
            displayName: url.lastPathComponent,
            addedAt: now,
            isOwned: false
        )
        items.insert(item, at: 0)
        try evictBeyondCapacity()
        try purge(now: now)
        return item
    }

    /// The item leaves the list only once its file is gone: one that stayed
    /// on disk would be reloaded from the directory at the next launch.
    public func remove(_ id: UUID) throws {
        guard let item = items.first(where: { $0.id == id }) else { return }
        try trash(item)
        items.removeAll { $0.id == id }
    }

    /// Removes every item whose file could be trashed.
    ///
    /// An item whose move to the Trash fails stays listed, for the same
    /// reason as `remove`: emptying the list up front showed a clear shelf
    /// that quietly refilled from the directory at the next launch. Every
    /// item is attempted; the first failure is rethrown afterwards.
    public func clear() throws {
        var firstError: (any Error)?
        for item in items {
            do {
                try trash(item)
                items.removeAll { $0.id == item.id }
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }

    /// Drops items whose file no longer exists, returning what went.
    ///
    /// A file can be moved or deleted from underneath the shelf -- in
    /// Finder, or a referenced capture tidied out of `~/Pictures` -- and
    /// nothing watches the disk for that, by design. Called when the shelf
    /// is shown instead: one `fileExists` per item, at most twenty, at the
    /// moment a stale tile would be seen. Nothing is trashed; there is
    /// nothing left to trash.
    @discardableResult
    public func pruneMissing() -> [ShelfItem] {
        let missing = items.filter { !fileManager.fileExists(atPath: $0.url.path) }
        guard !missing.isEmpty else { return [] }
        let missingIDs = Set(missing.map(\.id))
        items.removeAll { missingIDs.contains($0.id) }
        return missing
    }

    /// Removes anything older than `maxAge`, returning what went.
    ///
    /// Called on launch and after each add — never on a timer. A shelf can
    /// only grow when something is added to it, so nothing needs to watch
    /// it.
    ///
    /// The same rule as `clear`: an item leaves the list only once its file
    /// is in the Trash. The purge runs unattended at launch, so a failure
    /// here used to be invisible twice over -- the tile vanished, and the
    /// file came back at the next launch to be purged, and fail, again.
    /// Every expired item is attempted; the first failure is rethrown.
    @discardableResult
    public func purge(now: Date) throws -> [ShelfItem] {
        let expired = items.filter { now.timeIntervalSince($0.addedAt) > Self.maxAge }
        guard !expired.isEmpty else { return [] }

        var removed: [ShelfItem] = []
        var firstError: (any Error)?
        for item in expired {
            do {
                try trash(item)
                items.removeAll { $0.id == item.id }
                removed.append(item)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
        return removed
    }

    // MARK: - Internals

    /// Appends " 2", " 3", ... before the extension until the name is free.
    private func uniqueURL(for name: String) -> URL {
        let candidate = directory.appendingPathComponent(name)
        guard fileManager.fileExists(atPath: candidate.path) else { return candidate }

        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        while true {
            let suffixed = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            let url = directory.appendingPathComponent(suffixed)
            if !fileManager.fileExists(atPath: url.path) { return url }
            n += 1
        }
    }

    /// Trashes the oldest items until the shelf is back at capacity.
    ///
    /// The oldest leaves the list only after its file is gone, like every
    /// other removal. If it cannot be trashed the shelf stays over capacity
    /// and the error is thrown: a list that dropped it would show twenty
    /// while the directory holds twenty-one, and the next launch would
    /// reload them all. The next add tries again.
    private func evictBeyondCapacity() throws {
        while items.count > Self.capacity, let oldest = items.last {
            try trash(oldest)
            items.removeLast()
        }
    }

    /// Removal is always to the Trash.
    ///
    /// Eviction and purging are automatic and silent. A file dropped here
    /// whose original was later deleted has no other copy, so `removeItem`
    /// would destroy it without the user ever deciding to. `removeItem`
    /// must not appear in this module.
    /// Moves an item's file to the Trash -- **only if the shelf owns it**.
    ///
    /// A referenced file lives somewhere the user chose, and is usually the
    /// only copy of something they just made. The shelf's retention rules are
    /// about reclaiming space it allocated; applying them to a file it merely
    /// points at would mean a photograph taken this morning going to the Trash
    /// next week because twenty things were dragged onto the notch.
    private func trash(_ item: ShelfItem) throws {
        guard item.isOwned else { return }
        guard fileManager.fileExists(atPath: item.url.path) else { return }
        try fileManager.trashItem(at: item.url, resultingItemURL: nil)
    }
}
