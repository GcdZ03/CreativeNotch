import Foundation
import Observation

/// The clipboard history: fifty entries, newest first, in memory only.
///
/// There is no `load`, no directory, and no file handle in this type.
/// "Cleared on quit" is not a feature implemented here — it is what
/// happens when nothing is ever written down. `SECURITY.md` makes that a
/// promise, and `ClipboardStoreTests.theStoreNeverTouchesTheFileSystem`
/// pins it by reading this file.
///
/// `@MainActor` because every caller is: the poller, the view, and the
/// menu bar item.
@MainActor
@Observable
public final class ClipboardStore {

    public static let capacity = 50

    /// The ceiling on everything the ring holds, together.
    ///
    /// A count cap alone bounds this at `capacity × maxImageBytes` — half
    /// a gigabyte, resident for the life of the process. That is a real
    /// number rather than a pathological one: an uncompressed retina
    /// screenshot is tens of megabytes, and this app is aimed at people
    /// who copy them all day.
    ///
    /// Transcoding to PNG at capture (see `NSPasteboard.clipboardCapture`)
    /// makes the typical entry roughly a tenth of that. This is the
    /// guarantee that holds even when it doesn't — a screenshot of noise
    /// compresses to nothing at all.
    public static let maxTotalBytes = 100_000_000

    /// Newest first.
    public private(set) var entries: [ClipboardEntry] = []

    public var totalBytes: Int {
        entries.reduce(0) { $0 + $1.content.byteCount }
    }

    public init() {}

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

        if let index = entries.firstIndex(where: { $0.content == content }) {
            var promoted = entries.remove(at: index)
            promoted.addedAt = now
            entries.insert(promoted, at: 0)
            return promoted
        }

        let entry = ClipboardEntry(id: UUID(), content: content, addedAt: now)
        entries.insert(entry, at: 0)
        evictBeyondLimits()
        return entry
    }

    public func clear() {
        entries.removeAll()
    }

    /// Eviction happens only after an insert, never on a timer: a ring can
    /// only grow when something is added to it.
    ///
    /// Two limits, both oldest-first. The count cap is what the spec
    /// describes; the byte budget is what actually bounds memory, since
    /// fifty entries of wildly different sizes is not a fixed cost.
    ///
    /// The `count > 1` guard means the entry just recorded is never the
    /// one evicted. It is unreachable while the per-entry cap is far below
    /// the budget — but without it, raising `maxImageBytes` past
    /// `maxTotalBytes` some day would turn `record` into a no-op that
    /// silently discarded exactly what the user had just copied.
    private func evictBeyondLimits() {
        while entries.count > Self.capacity {
            entries.removeLast()
        }
        while entries.count > 1, totalBytes > Self.maxTotalBytes {
            entries.removeLast()
        }
    }
}
