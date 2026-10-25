import Foundation
import CreativeNotchCore

/// Where download progress comes from, behind a seam.
///
/// The real one subscribes to file progress publishing; a test hands in a
/// fake that plays `DownloadEvent`s, so no suite subscribes to anything or
/// waits on a browser.
@MainActor
protocol DownloadProgressSource: AnyObject {
    /// Starts reporting progress published for files in `folder`. Events
    /// arrive on the main actor, in the order they happened.
    func start(watching folder: URL, onEvent: @escaping @MainActor @Sendable (DownloadEvent) -> Void)
    /// Stops reporting, and drops every subscription and observation.
    func stop()
}

/// Download progress the way Finder gets it: `Progress.addSubscriber
/// (forFileURL:withPublishingHandler:)` on the Downloads folder.
///
/// **Event-driven end to end.** A browser publishes an `NSProgress` for the
/// file it is writing — Safari does for every download, which is how Finder
/// draws the bar under its icon — and the system calls the handler here when
/// one appears and the returned unpublishing handler when it goes. Between
/// those, key-value observation of the unit counts reports movement. Nothing
/// is polled, and with nothing downloading nothing runs at all.
///
/// Off the main actor the work is copying numbers out of the `Progress`, and
/// `ProgressRelay` forwards a reading only when its whole percent changes:
/// a browser can report every chunk it writes, and the main thread should
/// wake once per percent, not once per chunk.
@MainActor
final class FileProgressSource: DownloadProgressSource {
    private var subscriber: Any?
    private var relay: ProgressRelay?

    var isSubscribed: Bool { subscriber != nil }

    func start(watching folder: URL, onEvent: @escaping @MainActor @Sendable (DownloadEvent) -> Void) {
        guard subscriber == nil else { return }
        let relay = ProgressRelay(deliver: ProgressRelay.onMain(onEvent))
        self.relay = relay
        subscriber = Progress.addSubscriber(forFileURL: folder) { progress in
            relay.published(progress)
        }
    }

    func stop() {
        if let subscriber { Progress.removeSubscriber(subscriber) }
        subscriber = nil
        relay?.invalidate()
        relay = nil
    }
}

/// Turns published `Progress` objects into `DownloadEvent`s.
///
/// Called from whatever queue the progress service uses, so it holds its
/// bookkeeping under a lock and hands events to `deliver`, which in the app
/// is a hop to the main queue. **The hop happens under the lock**, so events
/// reach the main queue in the order they were decided — a change cannot
/// overtake the publish it follows, nor an unpublish the change before it.
///
/// `@unchecked Sendable` because the lock is what makes it safe, and the
/// compiler cannot see a lock.
final class ProgressRelay: @unchecked Sendable {
    typealias Deliver = @Sendable (DownloadEvent) -> Void

    private let lock = NSLock()
    private let deliver: Deliver
    private var observations: [DownloadID: [NSKeyValueObservation]] = [:]
    /// What was last forwarded for each download, to drop readings that
    /// would draw the same thing.
    private var lastForwarded: [DownloadID: DownloadReading] = [:]
    private var isInvalidated = false

    init(deliver: @escaping Deliver) {
        self.deliver = deliver
    }

    /// Delivery on the main queue, in order. `DispatchQueue.main` rather than
    /// a `Task`: tasks started from different threads promise no order.
    static func onMain(_ onEvent: @escaping @MainActor @Sendable (DownloadEvent) -> Void) -> Deliver {
        { event in
            DispatchQueue.main.async { MainActor.assumeIsolated { onEvent(event) } }
        }
    }

    /// How many downloads are being observed. For tests.
    var observedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return observations.count
    }

    /// A progress was published in the watched folder. Returns the handler
    /// the system calls when it is unpublished, or `nil` for one that is not
    /// a download (Finder copying a file in) and is not watched at all.
    func published(_ progress: Progress) -> Progress.UnpublishingHandler? {
        let fileURL = Self.fileURL(of: progress)
        guard DownloadName.isDownload(
            operationKind: Self.operationKind(of: progress), fileURL: fileURL
        ) else { return nil }

        let id = DownloadID()
        let first = Self.reading(of: progress)
        // The observations capture the relay and the id, never the progress:
        // KVO hands the object back to each change handler.
        let changed: @Sendable (Progress) -> Void = { [weak self] progress in
            self?.changed(id, Self.reading(of: progress))
        }
        let tokens = [
            progress.observe(\.completedUnitCount) { progress, _ in changed(progress) },
            progress.observe(\.totalUnitCount) { progress, _ in changed(progress) },
            progress.observe(\.isCancelled) { progress, _ in changed(progress) },
        ]

        lock.lock()
        guard !isInvalidated else {
            lock.unlock()
            tokens.forEach { $0.invalidate() }
            return nil
        }
        observations[id] = tokens
        lastForwarded[id] = first
        deliver(.published(id, first))
        lock.unlock()

        return { [weak self] in self?.unpublished(id) }
    }

    private func changed(_ id: DownloadID, _ reading: DownloadReading) {
        lock.lock(); defer { lock.unlock() }
        guard !isInvalidated, let last = lastForwarded[id] else { return }
        guard Self.drawsDifferently(reading, from: last) else { return }
        lastForwarded[id] = reading
        deliver(.changed(id, reading))
    }

    private func unpublished(_ id: DownloadID) {
        lock.lock(); defer { lock.unlock() }
        guard let tokens = observations.removeValue(forKey: id) else { return }
        tokens.forEach { $0.invalidate() }
        lastForwarded[id] = nil
        guard !isInvalidated else { return }
        deliver(.unpublished(id))
    }

    /// Drops every observation; nothing is delivered after this returns.
    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        isInvalidated = true
        for tokens in observations.values { tokens.forEach { $0.invalidate() } }
        observations.removeAll()
        lastForwarded.removeAll()
    }

    /// Whether a reading would change anything the tracker shows or decides:
    /// its whole percent, whether its length is known, whether it was
    /// cancelled. Bytes within the same percent change nothing on screen, and
    /// the percent reaching 100 is what completion is judged on, so that
    /// reading is never dropped.
    static func drawsDifferently(_ next: DownloadReading, from last: DownloadReading) -> Bool {
        next.percent != last.percent
            || (next.total > 0) != (last.total > 0)
            || next.isCancelled != last.isCancelled
            || next.fileURL != last.fileURL
    }

    /// The file a progress is about, from `fileURL` or else from `userInfo`.
    ///
    /// **Not `progress.fileURL` alone.** For another process's progress — a
    /// browser's download, which is the only kind this ever sees — the object
    /// the subscriber is handed answers `nil` from `fileURL` and
    /// `fileOperationKind`, while the same values sit in `userInfo` (measured
    /// against Safari and Chrome on macOS 26, 2026-10-25). Reading only the
    /// accessors filtered out every real download in v0.13.0.
    static func fileURL(of progress: Progress) -> URL? {
        if let url = progress.fileURL { return url }
        switch progress.userInfo[.fileURLKey] {
        case let url as URL: return url
        case let url as NSURL: return url as URL
        case let string as String where string.hasPrefix("file:"): return URL(string: string)
        case let path as String: return URL(fileURLWithPath: path)
        default: return nil
        }
    }

    /// The operation a progress describes, from `fileOperationKind` or else
    /// from `userInfo`, for the same reason as `fileURL(of:)`.
    static func operationKind(of progress: Progress) -> String? {
        if let kind = progress.fileOperationKind { return kind.rawValue }
        switch progress.userInfo[.fileOperationKindKey] {
        case let kind as Progress.FileOperationKind: return kind.rawValue
        case let kind as String: return kind
        default: return nil
        }
    }

    static func reading(of progress: Progress) -> DownloadReading {
        DownloadReading(
            fileURL: fileURL(of: progress),
            completed: progress.completedUnitCount,
            total: progress.totalUnitCount,
            isCancelled: progress.isCancelled
        )
    }
}
