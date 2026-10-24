import Foundation
import Observation

/// The clipboard history: fifty entries by default (25 to 100, chosen in
/// Settings), newest first, in memory only.
///
/// There is no `load`, no directory, and no file handle in this type.
/// "Cleared on quit" is not a feature implemented here — it is what
/// happens when nothing is ever written down. `SECURITY.md` makes that a
/// promise, and `ClipboardStoreTests.theStoreNeverTouchesTheFileSystem`
/// pins it by reading this file.
///
/// Pinned entries are in memory only too (2026-10-24). A pin is a way to
/// keep something to hand for the session, not a vault: writing pins down
/// would put whatever the person copied — often something private — on disk,
/// and break the promise above for the one kind of entry most likely to
/// matter. Quitting forgets pins with everything else.
///
/// `@MainActor` because every caller is: the poller, the view, and the
/// menu bar item.
@MainActor
@Observable
public final class ClipboardStore {

    /// What a fresh install gets: `Limits`' default, spelled once there.
    public static let defaultCapacity = Limits.defaultClipboardCapacity

    /// How many entries the ring holds. Chosen in Settings (2026-10-24);
    /// never below one, or recording would forget what was just copied.
    public private(set) var capacity: Int

    /// The ceiling on everything the ring holds, together.
    ///
    /// A count cap alone bounds this at `capacity × maxImageBytes` — half
    /// a gigabyte at the default size, a whole one at the largest, resident for the life of the process. That is a real
    /// number rather than a pathological one: an uncompressed retina
    /// screenshot is tens of megabytes, and this app is aimed at people
    /// who copy them all day.
    ///
    /// Transcoding to PNG at capture (see `NSPasteboard.clipboardCapture`)
    /// makes the typical entry roughly a tenth of that. This is the
    /// guarantee that holds even when it doesn't — a screenshot of noise
    /// compresses to nothing at all.
    public static let maxTotalBytes = 100_000_000

    /// How many entries may be pinned at once.
    ///
    /// Pins are exempt from both limits below, so without a ceiling of their
    /// own they would be a way round them: a hundred pinned screenshots is a
    /// gigabyte nobody can evict. Ten is a handful to keep at hand, and bounds
    /// what pins alone can hold at `maxPinned × maxImageBytes`, the same
    /// order as the byte budget.
    nonisolated public static let maxPinned = 10

    /// The pins, the most recently pinned first, then everything else, newest
    /// first. One array in display order rather than two, so the view, the
    /// search and the menu bar all read the same list.
    public private(set) var entries: [ClipboardEntry] = []

    public var totalBytes: Int {
        entries.reduce(0) { $0 + $1.content.byteCount }
    }

    public var pinnedCount: Int {
        entries.reduce(0) { $0 + ($1.isPinned ? 1 : 0) }
    }

    /// Whether another entry may be pinned. The row's Pin is disabled when
    /// not, rather than refusing after the click.
    public var canPin: Bool { pinnedCount < Self.maxPinned }

    /// What Clear would take: everything but the pins. The menu bar's "Clear
    /// Clipboard (n)" and the pane's Clear read this, so neither offers to
    /// clear a history that holds only pins.
    public var clearableCount: Int { entries.count - pinnedCount }

    /// How a pin request went. `limitReached` is the only one the person is
    /// told about; the other two are a stale menu racing the poller.
    public enum PinResult: Equatable, Sendable {
        case pinned
        case alreadyPinned
        case limitReached
        case unknown
    }

    public init(capacity: Int = ClipboardStore.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    /// Applies a new history size from Settings, at once (2026-10-24).
    ///
    /// Shrinking forgets the oldest straight away, through the same eviction
    /// a copy runs, rather than leaving the ring over size until the next
    /// copy happens to trim it. The byte budget is not a setting and is
    /// unchanged: it is what bounds memory whatever the count.
    public func setCapacity(_ capacity: Int) {
        self.capacity = max(1, capacity)
        evictBeyondLimits()
    }

    /// Records `content`, returning the entry it became — or `nil` if the
    /// ring refused it.
    ///
    /// Re-copying something already here **promotes** it: the existing
    /// entry moves to the front and its timestamp is refreshed, rather
    /// than a second copy being appended. Fifty slots therefore hold fifty
    /// distinct things, and re-copying one value cannot flush the history.
    ///
    /// It also makes the app's own paste-back a no-op by construction.
    /// Writing an entry back to the pasteboard bumps `changeCount`, so the
    /// poller sees its own write; promotion resolves that to the same
    /// entry returning to the front, which is the correct outcome anyway.
    /// The alternative — suppressing the change count we ourselves caused
    /// — is a special case that would have to stay correct forever.
    @discardableResult
    public func record(_ content: ClipboardContent, now: Date) -> ClipboardEntry? {
        // The ring enforces its own invariant rather than trusting the
        // caller. `NSPasteboard.clipboardCapture()` checks too, but only
        // so it can judge an image at the size it will be stored at.
        guard ClipboardLimits.accepts(content) else { return nil }

        // A promoted pin goes to the top of the pins, and stays pinned:
        // copying a pin back out is the commonest thing done to one, and
        // must not quietly unpin it. Anything else goes to the top of the
        // rest, just under the pins.
        if let index = entries.firstIndex(where: { $0.content == content }) {
            var promoted = entries.remove(at: index)
            promoted.addedAt = now
            entries.insert(promoted, at: promoted.isPinned ? 0 : pinnedCount)
            return promoted
        }

        let entry = ClipboardEntry(id: UUID(), content: content, addedAt: now)
        entries.insert(entry, at: pinnedCount)
        evictBeyondLimits()
        return entry
    }

    /// Pins an entry: it moves to the very top and stays there, through the
    /// ring's limits and a Clear, until it is unpinned or removed.
    @discardableResult
    public func pin(_ id: UUID) -> PinResult {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return .unknown }
        guard !entries[index].isPinned else { return .alreadyPinned }
        guard canPin else { return .limitReached }
        var pinned = entries.remove(at: index)
        pinned.isPinned = true
        entries.insert(pinned, at: 0)
        return .pinned
    }

    /// Unpins an entry, returning it to where its time puts it among the
    /// rest — the unpinned part of the list always reads newest first, so a
    /// row does not land somewhere its timestamp contradicts.
    ///
    /// It does not evict. The ring may be over size for a moment if pins had
    /// been holding it there; the next copy trims it, as a smaller history
    /// size does, and an unpin that made something vanish would be a worse
    /// surprise than a list one longer than its size until then.
    public func unpin(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }),
              entries[index].isPinned else { return }
        var unpinned = entries.remove(at: index)
        unpinned.isPinned = false
        let insertAt = entries.indices.first {
            !entries[$0].isPinned && entries[$0].addedAt <= unpinned.addedAt
        } ?? entries.endIndex
        entries.insert(unpinned, at: insertAt)
    }

    /// Clears the history and keeps the pins.
    ///
    /// Not a question, and not everything: a pin is the person saying "keep
    /// this", and Clear is them sweeping away what they did not say that
    /// about. Asking each time would put a dialog behind the menu bar item,
    /// which has nowhere to show one, and taking the pins would make pinning
    /// promise less than it says. Unpin, or a row's Remove, is how a pin goes.
    public func clear() {
        entries.removeAll { !$0.isPinned }
    }

    /// Forgets everything, pins included — for switching the module off,
    /// where off means the app holds nothing.
    public func removeAll() {
        entries.removeAll()
    }

    /// Forgets one entry — the row's Delete.
    ///
    /// An unknown id is a no-op rather than an error: the id comes from a
    /// context menu built at the last redraw, and the poller can have
    /// evicted that entry since. Unlike `ShelfStore.remove`, nothing here
    /// can fail, because there is no file behind an entry to move.
    public func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
    }

    /// Eviction happens only after an insert or a smaller size, never on a
    /// timer: a ring can only grow when something is added to it.
    ///
    /// Two limits, both oldest-first. The count cap is what the spec
    /// describes; the byte budget is what actually bounds memory, since
    /// fifty entries of wildly different sizes is not a fixed cost.
    ///
    /// Pins count towards both limits but are never what either evicts:
    /// the oldest *unpinned* entry goes instead — always the last element,
    /// since the pins sit at the front. Pinned bytes counting is what keeps
    /// the budget a bound on memory rather than on unpinned memory.
    ///
    /// The guard that one unpinned entry is always left means the entry
    /// just recorded is never the one evicted, even with every other slot
    /// pinned. It is also unreachable from the byte limit while the
    /// per-entry cap is far below the budget — but without it, raising
    /// `maxImageBytes` past `maxTotalBytes` some day would turn `record`
    /// into a no-op that silently discarded exactly what the user had just
    /// copied.
    private func evictBeyondLimits() {
        while entries.count > capacity, clearableCount > 1 {
            entries.removeLast()
        }
        while clearableCount > 1, totalBytes > Self.maxTotalBytes {
            entries.removeLast()
        }
    }
}
