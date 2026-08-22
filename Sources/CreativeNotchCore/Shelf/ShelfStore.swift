import Foundation

/// The shelf's contents and every file operation on them.
///
/// Lives in `CreativeNotchCore` because `FileManager` is Foundation, not
/// AppKit — which puts the code that can destroy a file in the target that
/// runs headlessly in CI.
///
/// `@MainActor` because every caller is: the drop target, the view, and the
/// menu bar item. File I/O on the main actor is acceptable at this scale —
/// twenty items, and disk is touched only on add or remove.
@MainActor
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
    /// date, which is what the 7-day purge measures against.
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

    public func remove(_ id: UUID) throws {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items.remove(at: index)
        try trash(item)
    }

    public func clear() throws {
        let all = items
        items.removeAll()
        for item in all { try trash(item) }
    }

    /// Removes anything older than `maxAge`, returning what went.
    ///
    /// Called on launch and after each add — never on a timer. A shelf can
    /// only grow when something is added to it, so nothing needs to watch
    /// it.
    @discardableResult
    public func purge(now: Date) throws -> [ShelfItem] {
        let expired = items.filter { now.timeIntervalSince($0.addedAt) > Self.maxAge }
        guard !expired.isEmpty else { return [] }

        let expiredIDs = Set(expired.map(\.id))
        items.removeAll { expiredIDs.contains($0.id) }
        for item in expired { try trash(item) }
        return expired
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

    private func evictBeyondCapacity() throws {
        while items.count > Self.capacity {
            let oldest = items.removeLast()
            try trash(oldest)
        }
    }

    /// Removal is always to the Trash.
    ///
    /// Eviction and purging are automatic and silent. A file dropped here
    /// whose original was later deleted has no other copy, so `removeItem`
    /// would destroy it without the user ever deciding to. `removeItem`
    /// must not appear in this module.
    private func trash(_ item: ShelfItem) throws {
        guard fileManager.fileExists(atPath: item.url.path) else { return }
        try fileManager.trashItem(at: item.url, resultingItemURL: nil)
    }
}
