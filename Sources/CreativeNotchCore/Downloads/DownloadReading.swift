import Foundation

/// One published file progress, identified for as long as it stays published.
///
/// An identity of our own rather than the file URL: a browser that restarts a
/// download publishes a second progress for the same file while the first is
/// still being torn down, and keying on the URL would let the late unpublish
/// of the first remove the second.
public struct DownloadID: Hashable, Sendable {
    public let raw: UUID

    public init(_ raw: UUID = UUID()) {
        self.raw = raw
    }
}

/// What a file progress said, copied out of the `Progress` at the moment it
/// said it.
///
/// A value rather than the `Progress` itself, because a `Progress` is a live,
/// non-`Sendable` object that another process keeps writing to — the tracker
/// has to reason about a reading, not about something that changes while it
/// looks.
public struct DownloadReading: Equatable, Sendable {
    public var fileURL: URL?
    public var completed: Int64
    /// Zero or negative when the publisher does not know — a server that sent
    /// no length. Never treated as zero bytes to go.
    public var total: Int64
    public var isCancelled: Bool

    public init(fileURL: URL?, completed: Int64, total: Int64, isCancelled: Bool = false) {
        self.fileURL = fileURL
        self.completed = completed
        self.total = total
        self.isCancelled = isCancelled
    }

    /// Whole percent, floored, or `nil` when the total is unknown.
    ///
    /// Floored so a download never reads 100% before it has finished, and
    /// clamped so a publisher overshooting its own total draws a full ring
    /// rather than past it.
    ///
    /// **This is also the redraw schedule.** A browser can report progress
    /// for every chunk it writes, thousands of times a minute. The subscriber
    /// forwards a reading only when this number changes, so the main thread
    /// wakes at most a hundred times per download however fast the bytes
    /// arrive — the timer's "display granularity is the redraw schedule",
    /// applied to bytes.
    public var percent: Int? {
        guard total > 0 else { return nil }
        let ratio = Double(max(completed, 0)) / Double(total)
        return min(100, max(0, Int((ratio * 100).rounded(.down))))
    }

    /// Whether the last reading reached the total.
    var reachedTotal: Bool { total > 0 && completed >= total }
}

/// What the subscriber reports.
///
/// The three callbacks file progress publishing has — a progress appears, it
/// moves, it goes — as values, so a fake can play a download through the
/// whole pipeline without a browser.
public enum DownloadEvent: Equatable, Sendable {
    case published(DownloadID, DownloadReading)
    case changed(DownloadID, DownloadReading)
    case unpublished(DownloadID)
}

/// Names, and which progresses are downloads at all.
public enum DownloadName {

    /// The temporary extensions browsers download into before renaming:
    /// Safari's `.download` bundle, Chrome's `.crdownload`, Firefox's `.part`,
    /// Opera's `.opdownload`, and the generic `.partial`.
    public static let partialExtensions: Set<String> = [
        "download", "crdownload", "part", "partial", "opdownload",
    ]

    /// `Progress.FileOperationKind.downloading`, spelled out so this file's
    /// tests can pass a kind without constructing a `Progress`.
    public static let downloadingKind = Progress.FileOperationKind.downloading.rawValue

    /// Whether `url` carries a partial extension, so that it will be renamed
    /// when the download finishes.
    public static func isPartial(_ url: URL) -> Bool {
        partialExtensions.contains(url.pathExtension.lowercased())
    }

    /// Where the file will be once it has finished: the partial extension
    /// taken off, or the URL unchanged when it had none.
    public static func finalURL(for url: URL) -> URL {
        isPartial(url) ? url.deletingPathExtension() : url
    }

    /// The name the file will have, which is the one worth showing. "Download"
    /// for a publisher that named no file.
    public static func displayName(for url: URL?) -> String {
        let fallback = String(localized: "Download", bundle: .creativeNotch, comment: "The name of a download whose file has no name")
        guard let url else { return fallback }
        let name = finalURL(for: url).lastPathComponent
        return name.isEmpty ? fallback : name
    }

    /// Whether a published progress is a download rather than, say, Finder
    /// copying a file into the folder — which publishes a progress too.
    ///
    /// A stated kind decides. With no kind stated, only a browser's partial
    /// extension says download: guessing yes for anything unlabelled would
    /// put a copy or an unzip in the notch as though it had come off the
    /// network.
    public static func isDownload(operationKind: String?, fileURL: URL?) -> Bool {
        if let operationKind { return operationKind == downloadingKind }
        guard let fileURL else { return false }
        return isPartial(fileURL)
    }
}
