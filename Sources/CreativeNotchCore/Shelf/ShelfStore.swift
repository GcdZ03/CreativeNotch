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
/// fifty items at most, and disk is touched only on add or remove — with
/// one exception, the copy of a dropped file.
///
/// **A dropped file is copied off the main actor.** A multi-gigabyte drop
/// from another volume used to hold the main thread for the length of the
/// copy. `performDragOperation` must still answer accepted-or-refused before
/// it returns, and spec section 9 still refuses a drop that cannot be
/// stored, so `add(.file)` splits in two:
///
/// - **At drop time, synchronously and cheaply**, it refuses what is known
///   to fail: a source that is gone or unreadable, a shelf directory that
///   cannot be written, a regular file bigger than the volume's free space.
///   A folder is not walked to measure it — that walk could be the slow
///   part — so it is accepted and its copy may fail later.
/// - **Accepted**, it reserves the destination name at once and lists a
///   *pending* item under it, so a second drop of the same name, or a text
///   drop, is suffixed rather than racing `uniqueURL` for it. The copy runs
///   on `copier` into a hidden `.<uuid>.partial` in the shelf directory —
///   `load` already skips hidden files — and is renamed into the reserved
///   name, stamped with the drop time, and marked ready back on the main
///   actor. A failure deletes the partial, drops the pending item and calls
///   `onCopyFailed`.
///
/// Every copy goes this way, same volume or not: an APFS clone finishes
/// almost at once, and one path is simpler than two. A quit mid-copy
/// abandons it; the next launch deletes the partial. Text and image drops
/// are small and stay synchronous, and `addReference` copies nothing.
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

    /// Only the items with a file behind them: what AirDrop All and Clear
    /// act on, and what a drag out can carry.
    public var readyItems: [ShelfItem] { items.filter { !$0.isPending } }

    /// Told when a dropped file's copy fails after the drop was accepted,
    /// with the pending item that has just been taken off the list.
    ///
    /// The drop already returned true, so this is the only place the
    /// failure can surface. How long the pane mentions it is a UI decision,
    /// so the store reports and forgets.
    @ObservationIgnored
    public var onCopyFailed: ((ShelfItem, any Error) -> Void)?

    private let directory: URL
    private let fileManager: FileManager
    private let copier: ShelfCopier
    /// Where `trash(_:)` sends a file; the real Trash outside tests.
    private let trashCan: ShelfTrash

    /// The copies in flight, by pending item. Kept so a test can wait for
    /// them; nothing ever cancels one.
    @ObservationIgnored
    private var copies: [UUID: Task<Void, Never>] = [:]

    /// The limits are taken here, not read later, so the app can hand over
    /// the saved ones before its launch purge runs: a purge against the
    /// default age would trash files a "30 days" shelf was promised to keep.
    public init(
        directory: URL,
        fileManager: FileManager = .default,
        capacity: Int = ShelfStore.defaultCapacity,
        maxAge: TimeInterval? = ShelfStore.defaultMaxAge,
        copier: ShelfCopier = .system,
        trash: ShelfTrash = .system
    ) throws {
        self.directory = directory
        self.fileManager = fileManager
        self.copier = copier
        self.trashCan = trash
        self.capacity = max(1, capacity)
        self.maxAge = maxAge
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        Self.discardStalePartials(in: directory, fileManager: fileManager)
        items = Self.load(from: directory, fileManager: fileManager)
    }

    /// Why a drop was refused before anything was copied.
    public enum AddError: Error, Equatable {
        /// The dropped file is gone, or cannot be read.
        case sourceUnavailable(URL)
        /// The shelf directory cannot be written.
        case shelfNotWritable
        /// The file is bigger than the free space on the shelf's volume.
        case notEnoughSpace(needed: Int64, available: Int64)
    }

    /// Deletes the temporary copies a quit mid-copy left behind.
    ///
    /// They are hidden, so `load` never lists them and no removal would
    /// ever reach them; without this each abandoned copy would hold its
    /// space for good.
    private static func discardStalePartials(in directory: URL, fileManager: FileManager) {
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where isPartialName(name) {
            discardPartial(directory.appendingPathComponent(name), fileManager: fileManager)
        }
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

    /// Stores a drop. Text and images are written before this returns; a
    /// file is validated, listed as pending under its reserved name, and
    /// copied in the background -- see the type's note. Throws only when the
    /// drop should be refused.
    @discardableResult
    public func add(_ payload: DropPayload, now: Date) throws -> ShelfItem {
        let destination: URL
        switch payload {
        case .file(let source):
            return try beginCopy(of: source, now: now)
        case .text(let string):
            destination = uniqueURL(for: payload.suggestedName)
            try string.write(to: destination, atomically: true, encoding: .utf8)
        case .image(let data, _):
            destination = uniqueURL(for: payload.suggestedName)
            try data.write(to: destination, options: .atomic)
        }

        // The creation date is the record of the drop time -- no sidecar
        // index -- and `load` reads `addedAt` back from it, so it is set
        // for every payload kind. It matters most for a copied file, which
        // keeps the source's creation date: unstamped, a file made a month
        // ago and dropped this morning reloads as a month old and the
        // launch purge trashes it. `finishCopy` stamps those the same way.
        //
        // `try?` because the write has already landed: failing the drop now
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

    /// Waits until every copy in flight has landed or failed.
    ///
    /// For tests and nothing else: the app never waits on a copy, which is
    /// the point of copying in the background.
    public func waitForPendingCopies() async {
        while let task = copies.values.first {
            await task.value
        }
    }

    // MARK: - Copying a dropped file

    /// The synchronous half of a file drop: refuse, or reserve and list.
    private func beginCopy(of source: URL, now: Date) throws -> ShelfItem {
        try validate(source)

        let destination = uniqueURL(for: source.lastPathComponent)
        let partial = directory.appendingPathComponent(".\(UUID().uuidString).partial")
        let item = ShelfItem(
            id: UUID(),
            url: destination,
            displayName: destination.lastPathComponent,
            addedAt: now,
            isPending: true
        )
        items.insert(item, at: 0)
        // The pending item counts toward the capacity, so the shelf never
        // shows more tiles than its limit, but eviction passes it by.
        housekeep(sparing: item.id, now: now)

        let copier = self.copier
        // Inherits the main actor, so the hand-back is on it; the copier
        // itself runs elsewhere (`ShelfCopier.system` is detached).
        copies[item.id] = Task { [weak self] in
            do {
                try await copier.copy(source, partial)
                self?.finishCopy(of: item.id, from: partial)
            } catch {
                self?.failCopy(of: item.id, from: partial, error: error)
            }
        }
        return item
    }

    /// Refuses what is known to fail, cheaply, while the drop can still be
    /// refused.
    ///
    /// A folder is not measured: summing its tree could take as long as
    /// the copy this is meant to keep off the main thread.
    private func validate(_ source: URL) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory),
              fileManager.isReadableFile(atPath: source.path)
        else { throw AddError.sourceUnavailable(source) }

        guard fileManager.isWritableFile(atPath: directory.path)
        else { throw AddError.shelfNotWritable }

        guard !isDirectory.boolValue,
              let size = (try? fileManager.attributesOfItem(atPath: source.path))?[.size] as? NSNumber,
              let available = copier.availableCapacity(directory)
        else { return }
        if size.int64Value > available {
            throw AddError.notEnoughSpace(needed: size.int64Value, available: available)
        }
    }

    /// The copy landed: rename it into the reserved name and mark it ready.
    ///
    /// If something took the reserved name in the meantime -- a file put in
    /// the directory by hand; nothing in the store can -- the copy takes the
    /// next free name rather than failing after all that copying.
    private func finishCopy(of id: UUID, from partial: URL) {
        copies[id] = nil
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            Self.discardPartial(partial, fileManager: fileManager)
            return
        }
        let pending = items[index]
        let destination = fileManager.fileExists(atPath: pending.url.path)
            ? uniqueURL(for: pending.displayName)
            : pending.url
        do {
            try fileManager.moveItem(at: partial, to: destination)
        } catch {
            failCopy(of: id, from: partial, error: error)
            return
        }
        // As in `add`: the creation date is the record of the drop time.
        try? fileManager.setAttributes(
            [.creationDate: pending.addedAt], ofItemAtPath: destination.path)

        items[index] = ShelfItem(
            id: id,
            url: destination,
            displayName: destination.lastPathComponent,
            addedAt: pending.addedAt
        )
        // Pending items were passed over by the eviction their add ran; one
        // that is now ready can be evicted like any other.
        evictBeyondCapacity(sparing: id)
    }

    private func failCopy(of id: UUID, from partial: URL, error: any Error) {
        copies[id] = nil
        Self.discardPartial(partial, fileManager: fileManager)
        guard let item = items.first(where: { $0.id == id }) else { return }
        items.removeAll { $0.id == id }
        onCopyFailed?(item, error)
    }

    /// `.<uuid>.partial`: hidden, so `load` never lists it.
    private static func isPartialName(_ name: String) -> Bool {
        name.hasPrefix(".") && name.hasSuffix(".partial")
    }

    /// Deletes a temporary copy outright -- the one `removeItem` in this
    /// module, and why it is allowed here.
    ///
    /// A partial is never an item and never the only copy of anything: it
    /// is half of a copy whose original is still where it was dropped from.
    /// Sending it to the Trash would fill the user's Trash with fragments
    /// they never put on the shelf. The name check keeps this from ever
    /// deleting anything else.
    private static func discardPartial(_ url: URL, fileManager: FileManager) {
        guard isPartialName(url.lastPathComponent) else { return }
        try? fileManager.removeItem(at: url)
    }

    // MARK: - References

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
    ///
    /// A pending item is left alone: its copy is still running and would
    /// land a moment later under a name nothing lists. The tile offers no
    /// Remove while it copies, so this is only a backstop.
    public func remove(_ id: UUID) throws {
        guard let item = items.first(where: { $0.id == id }), !item.isPending else { return }
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
    ///
    /// Pending items stay listed, for the reason `remove` leaves them.
    @discardableResult
    public func clear() throws -> ShelfClearance {
        var entries: [ShelfClearance.Entry] = []
        var firstError: (any Error)?
        for item in items where !item.isPending {
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
    /// Owned files are moved back out of the Trash -- `ShelfTrash` reported
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
        // A pending item's file is not there *yet*; that is not missing.
        let missing = items.filter { !$0.isPending && !fileManager.fileExists(atPath: $0.url.path) }
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
    /// A pending item is never expired: it has no file yet, and its age
    /// counts from the drop once it is ready.
    @discardableResult
    public func purge(now: Date) throws -> [ShelfItem] {
        guard let maxAge else { return [] }
        let expired = items.filter { !$0.isPending && now.timeIntervalSince($0.addedAt) > maxAge }
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
    ///
    /// Free means no file on disk *and* not reserved by a pending item,
    /// whose file does not exist until its copy lands. Compared without
    /// case, as the default APFS volume does.
    private func uniqueURL(for name: String) -> URL {
        let reserved = Set(items.filter(\.isPending).map { $0.url.lastPathComponent.lowercased() })
        func isFree(_ url: URL) -> Bool {
            !reserved.contains(url.lastPathComponent.lowercased())
                && !fileManager.fileExists(atPath: url.path)
        }

        let candidate = directory.appendingPathComponent(name)
        guard !isFree(candidate) else { return candidate }

        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        while true {
            let suffixed = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            let url = directory.appendingPathComponent(suffixed)
            if isFree(url) { return url }
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
    ///
    /// Pending items **count** toward the capacity -- so the pane never
    /// shows more tiles than the limit while copies run -- but are never
    /// evicted, like a stuck file: there is nothing in the directory to
    /// trash, and the copy would land under a name nothing lists.
    /// `finishCopy` runs this again once a copy lands, so the shelf comes
    /// back to its capacity as soon as the pending items can be counted
    /// as evictable.
    private func evictBeyondCapacity(sparing spared: UUID?) {
        for candidate in items.reversed() where items.count > capacity {
            guard candidate.id != spared, !candidate.isPending else { continue }
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
    /// appears in this module only in `discardPartial`, for temporary
    /// copies that were never an item.
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
        return try trashCan.move(item.url)
    }
}
