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
/// fifty items at most, and disk is touched only on add or remove.
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

    /// What a fresh install gets: `Limits`' defaults, spelled once there.
    public static let defaultCapacity = Limits.defaultShelfCapacity
    public static let defaultMaxAge: TimeInterval = Limits.defaultShelfExpiry.maxAge!

    /// How many items the shelf holds before the oldest is evicted. Chosen in
    /// Settings (2026-10-24); never below one, or eviction would take the
    /// item an add just made.
    public private(set) var capacity: Int

    /// How old an item may get before the purge trashes it, or `nil` for
    /// never — which switches the purge off rather than setting a very
    /// large age.
    public private(set) var maxAge: TimeInterval?

    /// Newest first.
    public private(set) var items: [ShelfItem] = []

    private let directory: URL
    private let fileManager: FileManager

    /// The limits are taken here, not read later, so the app can hand over
    /// the saved ones before its launch purge runs: a purge against the
    /// default age would trash files a "30 days" shelf was promised to keep.
    public init(
        directory: URL,
        fileManager: FileManager = .default,
        capacity: Int = ShelfStore.defaultCapacity,
        maxAge: TimeInterval? = ShelfStore.defaultMaxAge
    ) throws {
        self.directory = directory
        self.fileManager = fileManager
        self.capacity = max(1, capacity)
        self.maxAge = maxAge
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        items = Self.load(from: directory, fileManager: fileManager)
    }

    /// Rebuilds the list from what is actually on disk.
    ///
    /// The directory is the source of truth: there is no sidecar index to
    /// fall out of step with it, and a file removed from underneath us
    /// simply stops appearing. `addedAt` comes from the file's creation
    /// date, which is what the age purge measures against -- and which
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
        housekeep(sparing: item.id, now: now)
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
        housekeep(sparing: item.id, now: now)
        return item
    }

    /// The item leaves the list only once its file is gone: one that stayed
    /// on disk would be reloaded from the directory at the next launch.
    public func remove(_ id: UUID) throws {
        guard let item = items.first(where: { $0.id == id }) else { return }
        try trash(item)
        items.removeAll { $0.id == id }
    }

    /// A clear that could not trash everything.
    ///
    /// Carries what it *did* take, so the items that went can still be
    /// undone: a plain rethrow would leave them in the Trash with no record
    /// of where they came from.
    public struct PartialClear: Error {
        public let clearance: ShelfClearance
        public let underlying: any Error
    }

    /// Removes every item whose file could be trashed, returning where each
    /// went so `restore(_:)` can undo it.
    ///
    /// An item whose move to the Trash fails stays listed, for the same
    /// reason as `remove`: emptying the list up front showed a clear shelf
    /// that quietly refilled from the directory at the next launch. Every
    /// item is attempted; if any failed, `PartialClear` is thrown with the
    /// first failure and the record of what did go.
    @discardableResult
    public func clear() throws -> ShelfClearance {
        var entries: [ShelfClearance.Entry] = []
        var firstError: (any Error)?
        for item in items {
            do {
                let trashedURL = try trash(item)
                items.removeAll { $0.id == item.id }
                entries.append(.init(item: item, trashedURL: trashedURL))
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        let clearance = ShelfClearance(entries: entries)
        if let firstError { throw PartialClear(clearance: clearance, underlying: firstError) }
        return clearance
    }

    /// Puts back what a `clear()` took, as far as it still can.
    ///
    /// Owned files are moved back out of the Trash -- `trashItem` reported
    /// where it put each one -- and keep their identity and drop time, so
    /// they return to the same place in the list and age from the original
    /// drop, not from the undo. A move preserves the creation date, which is
    /// what `load` reads `addedAt` back from. If something dropped since has
    /// taken the old name, the restored file is suffixed rather than
    /// overwriting it.
    ///
    /// An item that cannot come back is skipped and reported, not thrown:
    /// one file emptied out of the Trash should not cost the user the rest.
    /// Anything already listed again is left alone.
    ///
    /// Restoring can take the shelf over capacity if things were dropped in
    /// the meantime; the oldest are then evicted as after any add.
    @discardableResult
    public func restore(_ clearance: ShelfClearance) -> ShelfRestoration {
        var restored: [ShelfItem] = []
        var skipped: [ShelfItem] = []

        for entry in clearance.entries {
            let item = entry.item
            guard !items.contains(where: { $0.id == item.id }) else { continue }

            guard item.isOwned else {
                if fileManager.fileExists(atPath: item.url.path) {
                    restored.append(item)
                } else {
                    skipped.append(item)
                }
                continue
            }

            guard let trashed = entry.trashedURL,
                  fileManager.fileExists(atPath: trashed.path)
            else {
                skipped.append(item)
                continue
            }
            let destination = fileManager.fileExists(atPath: item.url.path)
                ? uniqueURL(for: item.displayName)
                : item.url
            do {
                try fileManager.moveItem(at: trashed, to: destination)
            } catch {
                skipped.append(item)
                continue
            }
            restored.append(ShelfItem(
                id: item.id,
                url: destination,
                displayName: destination.lastPathComponent,
                addedAt: item.addedAt
            ))
        }

        guard !restored.isEmpty else {
            return ShelfRestoration(restored: [], skipped: skipped)
        }
        items.append(contentsOf: restored)
        items.sort { $0.addedAt > $1.addedAt }
        // An eviction that cannot trash keeps its item listed, so nothing
        // is lost either way.
        evictBeyondCapacity(sparing: nil)
        return ShelfRestoration(restored: restored, skipped: skipped)
    }

    /// Applies new limits from Settings, at once (2026-10-24).
    ///
    /// Through the same eviction and purge an add runs, so a lowered limit
    /// follows every rule a full shelf does: oldest first, an item leaves the
    /// list only once its file is in the Trash, and one that will not go is
    /// skipped for the next oldest. Nothing is spared — there is no item just
    /// added to protect.
    ///
    /// Never throws, for the reason `housekeep` does not: the new limits are
    /// in force either way, and whatever could not be trashed stays listed to
    /// be tried again after the next add.
    public func setLimits(capacity: Int, maxAge: TimeInterval?, now: Date) {
        self.capacity = max(1, capacity)
        self.maxAge = maxAge
        evictBeyondCapacity(sparing: nil)
        _ = try? purge(now: now)
    }

    /// What `setLimits` would take if handed these limits now, without
    /// taking it (2026-10-24).
    ///
    /// Settings asks before it applies a lowered limit, so a change that
    /// would trash files is confirmed first and one that would not applies
    /// silently. Nothing here touches the disk or the list.
    public func previewLimits(capacity: Int, maxAge: TimeInterval?, now: Date) -> ShelfLimitRemoval {
        Self.removals(from: items, capacity: capacity, maxAge: maxAge, now: now)
    }

    /// The rule `setLimits` enforces, as a pure function of the list.
    ///
    /// Eviction first, oldest beyond the capacity, then the age purge over
    /// what is left — the order `setLimits` runs them in, so an item past
    /// both is counted once.
    ///
    /// **It assumes every file will go.** A file that refuses the Trash is
    /// skipped by eviction for the next oldest, so the count still holds for
    /// a lowered capacity even though *which* item goes differs; a stuck file
    /// past the expiry simply stays. The preview cannot know which files are
    /// stuck without trying to move them, which is the side effect it exists
    /// to avoid. Items are judged by list order and drop time alone.
    public nonisolated static func removals(
        from items: [ShelfItem],
        capacity: Int,
        maxAge: TimeInterval?,
        now: Date
    ) -> ShelfLimitRemoval {
        let capacity = max(1, capacity)
        let removed = items.enumerated().filter { index, item in
            let evicted = index >= capacity
            let expired = maxAge.map { now.timeIntervalSince(item.addedAt) > $0 } ?? false
            return evicted || expired
        }
        return ShelfLimitRemoval(items: removed.map(\.element))
    }

    /// Drops items whose file no longer exists, returning what went.
    ///
    /// A file can be moved or deleted from underneath the shelf -- in
    /// Finder, or a referenced capture tidied out of `~/Pictures` -- and
    /// nothing watches the disk for that, by design. Called when the shelf
    /// is shown instead: one `fileExists` per item, at most fifty, at the
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

    /// Removes anything older than `maxAge`, returning what went — nothing at
    /// all when `maxAge` is `nil`.
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
        guard let maxAge else { return [] }
        let expired = items.filter { now.timeIntervalSince($0.addedAt) > maxAge }
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

    /// The upkeep after an add: eviction, then the age purge.
    ///
    /// Never throws. By the time it runs the new item is copied and listed,
    /// so the add has succeeded; reporting a failure here would have the
    /// caller refuse a drop -- or log a capture as lost -- that is in fact
    /// on the shelf. And a file that cannot be trashed fails the same way
    /// every time, so a throwing upkeep would fail every add from then on.
    /// Whatever could not go stays listed and is tried again next time,
    /// as with every other removal.
    private func housekeep(sparing id: UUID, now: Date) {
        evictBeyondCapacity(sparing: id)
        _ = try? purge(now: now)
    }

    /// Trashes the oldest items until the shelf is back at capacity.
    ///
    /// An item leaves the list only after its file is gone, like every other
    /// removal: a list that dropped it would show the capacity while the directory
    /// holds one more, and the next launch would reload them all. One that
    /// cannot be trashed is skipped for the next oldest, so a single stuck
    /// file does not stall eviction and let the shelf grow without limit; the
    /// shelf stays over capacity only by the number of stuck files.
    ///
    /// `sparing` is the item just added. Evicting the thing the user just
    /// dropped, because older ones would not go, would refuse the drop in
    /// all but name.
    private func evictBeyondCapacity(sparing spared: UUID?) {
        for candidate in items.reversed() where items.count > capacity {
            guard candidate.id != spared else { continue }
            do {
                try trash(candidate)
                items.removeAll { $0.id == candidate.id }
            } catch {
                continue
            }
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
    ///
    /// Returns where the Trash put the file, which is what lets `clear` be
    /// undone; `nil` when nothing was moved.
    @discardableResult
    private func trash(_ item: ShelfItem) throws -> URL? {
        guard item.isOwned else { return nil }
        guard fileManager.fileExists(atPath: item.url.path) else { return nil }
        var resulting: NSURL?
        try fileManager.trashItem(at: item.url, resultingItemURL: &resulting)
        return resulting as URL?
    }
}

/// What a change of shelf limits would take off the shelf, and the words
/// Settings uses to ask before it does (2026-10-24).
///
/// The words live here rather than in the view so they can be tested: a
/// confirmation that says "Move 2 files to the Trash" when the two are
/// captures the shelf only links to would be the alarm that trains people to
/// click through it.
public struct ShelfLimitRemoval: Equatable, Sendable {
    /// In list order, newest first.
    public let items: [ShelfItem]

    public init(items: [ShelfItem]) {
        self.items = items
    }

    /// Nothing would go, so the change applies without asking.
    public var isEmpty: Bool { items.isEmpty }

    public var count: Int { items.count }

    /// The ones whose file actually goes to the Trash. A reference leaves the
    /// list and its file stays where it is.
    public var trashedCount: Int { items.filter(\.isOwned).count }

    private var linkedCount: Int { count - trashedCount }

    public var title: String {
        trashedCount > 0
            ? "Move \(Self.plural(trashedCount, "file")) from the shelf to the Trash?"
            : "Remove \(Self.plural(count, "item")) from the shelf?"
    }

    public var message: String {
        var message = "The new limit is lower than what the shelf holds now."
        if trashedCount > 0, linkedCount > 0 {
            message += " \(Self.plural(linkedCount, "linked item")) also \(linkedCount == 1 ? "leaves" : "leave") the shelf, but \(linkedCount == 1 ? "its file stays" : "their files stay") where \(linkedCount == 1 ? "it is" : "they are")."
        } else if trashedCount == 0 {
            message += " Their files stay where they are."
        }
        return message
    }

    /// The destructive button: what it does, not "OK".
    public var confirmLabel: String { trashedCount > 0 ? "Move to Trash" : "Remove" }

    private static func plural(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }
}
