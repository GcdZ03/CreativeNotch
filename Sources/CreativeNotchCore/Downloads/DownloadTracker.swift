import Foundation

/// What the downloads in progress add up to: the badge's ring and the peek's
/// line.
///
/// Quantised to whole percents (`DownloadReading.percent`), so two readings a
/// few bytes apart produce an *equal* summary. That equality is load-bearing:
/// `AppState.downloads` is an `Equatable` observed property, and the guard
/// `@Observable` emits drops an equal assignment — so a browser reporting
/// every chunk redraws the ring once per percent, not once per chunk.
public struct DownloadSummary: Equatable, Sendable {
    /// How many downloads are running.
    public let count: Int
    /// The byte-weighted aggregate, over the downloads whose length is known,
    /// or `nil` when none is.
    public let percent: Int?
    /// The first-started download's name. Shown alone when it is the only
    /// one.
    public let leadingName: String

    public init(count: Int, percent: Int?, leadingName: String) {
        self.count = count
        self.percent = percent
        self.leadingName = leadingName
    }

    /// The ring's fill, 0...1, or `nil` for an indeterminate download.
    public var fraction: Double? { percent.map { Double($0) / 100 } }

    /// "report.pdf", or "3 downloads".
    public var title: String {
        count == 1 ? leadingName : "\(count) downloads"
    }

    /// "42%", or `nil` when there is no percent to show — never a made-up 0%.
    public var percentText: String? { percent.map { "\($0)%" } }

    /// What VoiceOver reads, in words: "42%" read aloud is fine, but the
    /// sentence has to say what is at 42.
    public var spoken: String {
        let subject = count == 1 ? "Downloading \(leadingName)" : "\(count) downloads"
        guard let percent else { return subject }
        return "\(subject), \(percent) percent"
    }

    /// The badge's count, when there is more than one: "2"…"9", then "9+"
    /// so the slot's fixed width always holds it.
    public var countText: String? {
        guard count > 1 else { return nil }
        return count > 9 ? "9+" : "\(count)"
    }
}

/// A download that has just finished.
public struct DownloadCompletion: Equatable, Sendable {
    public let name: String
    /// The finished file, to reveal in Finder. `nil` when the publisher named
    /// no file, and then the peek offers nothing to click.
    public let url: URL?

    public init(name: String, url: URL?) {
        self.name = name
        self.url = url
    }

    /// The peek's line and its announcement.
    public var text: String { "Downloaded \(name)" }
}

/// The downloads module's whole judgement: which progresses are running,
/// what they add up to, and when one has *finished* rather than merely
/// stopped.
///
/// Pure, for the reason `PeekArbiter` is. A file progress's lifecycle has no
/// "finished" callback — a progress is published, changes, and is
/// unpublished, and an unpublish means finished, cancelled or abandoned
/// alike. Telling those apart is the interesting part, and it is testable
/// here with synthetic readings and no browser.
public struct DownloadTracker: Equatable, Sendable {
    /// Start order, kept so the leading name does not jump between two
    /// downloads as their percentages cross.
    private var order: [DownloadID] = []
    private var readings: [DownloadID: DownloadReading] = [:]

    public init() {}

    /// Applies one event, returning the completion it amounts to, if any.
    ///
    /// `finalFileExists` is asked only on an unpublish, and only for a
    /// progress published on a partial file: the existence of the renamed
    /// file is the fallback for a browser that never publishes its last
    /// chunk. A progress published on the final name itself gets no such
    /// fallback, because that file exists for the whole download.
    @discardableResult
    public mutating func apply(
        _ event: DownloadEvent,
        finalFileExists: (URL) -> Bool
    ) -> DownloadCompletion? {
        switch event {
        case .published(let id, let reading):
            if readings[id] == nil { order.append(id) }
            readings[id] = reading
            return nil

        case .changed(let id, let reading):
            // A late change for something already gone — after a reset, or
            // racing its own unpublish — must not bring it back.
            guard readings[id] != nil else { return nil }
            readings[id] = reading
            return nil

        case .unpublished(let id):
            guard let last = readings.removeValue(forKey: id) else { return nil }
            order.removeAll { $0 == id }
            guard !last.isCancelled else { return nil }
            let renamed = last.fileURL.map {
                DownloadName.isPartial($0) && finalFileExists(DownloadName.finalURL(for: $0))
            } ?? false
            guard last.reachedTotal || renamed else { return nil }
            return DownloadCompletion(
                name: DownloadName.displayName(for: last.fileURL),
                url: last.fileURL.map(DownloadName.finalURL(for:))
            )
        }
    }

    /// Forgets everything, as switching the module off does. A late
    /// unpublish for a forgotten download then completes nothing.
    public mutating func reset() {
        order.removeAll()
        readings.removeAll()
    }

    /// What is running, or `nil` when nothing is. A cancelled download has
    /// already left it, before the browser gets round to unpublishing.
    public var summary: DownloadSummary? {
        let running = order.compactMap { id in readings[id].flatMap { $0.isCancelled ? nil : $0 } }
        guard let first = running.first else { return nil }

        // Byte-weighted, over the downloads whose length is known: a 1 GB
        // download at 10% beside a finished 1 KB one is at 10%, not 55%.
        let known = running.filter { $0.total > 0 }
        let percent: Int?
        if known.isEmpty {
            percent = nil
        } else {
            let aggregate = DownloadReading(
                fileURL: nil,
                completed: known.reduce(0) { $0 + max($1.completed, 0) },
                total: known.reduce(0) { $0 + $1.total }
            )
            percent = aggregate.percent
        }
        return DownloadSummary(
            count: running.count,
            percent: percent,
            leadingName: DownloadName.displayName(for: first.fileURL)
        )
    }
}
