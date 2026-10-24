import Foundation
import CreativeNotchCore

/// The downloads module: asks for the Downloads folder, subscribes to its
/// file progress, and publishes what that adds up to.
///
/// **Switching it off stops everything it runs.** `stop()` cancels a pending
/// access check, removes the progress subscription and every observation
/// with it, forgets what it was tracking and publishes the absence — so the
/// badge goes, and the closed notch's hit-test region shrinks with it, the
/// moment the switch does.
///
/// **Not suspended by the activity gate**, the power module's shape. A
/// subscription costs nothing while nothing downloads, and suspending it
/// over a lock would miss a download finishing behind the lock screen and
/// leave its ring on the notch after unlock. What the gate does withhold is
/// the completion peek: an interruption timed to a moment, which replayed
/// after unlock would be a notification, which this app is not.
@MainActor
final class DownloadsController {

    /// Reads the folder once, off the main actor, to learn whether macOS
    /// lets the app see it. The first read is what makes macOS ask, so it
    /// runs only when the module is switched on.
    typealias AccessProbe = @Sendable (URL) async -> Bool

    let folder: URL
    private let source: DownloadProgressSource
    private let probeAccess: AccessProbe
    private let fileExists: (URL) -> Bool

    private(set) var tracker = DownloadTracker()
    private(set) var access: DownloadsAccess = .unknown
    private(set) var isSubscribed = false
    private var isEnabled = false
    private var isActive = true

    /// The running access check. Exposed so a test can await it instead of
    /// sleeping, like `AppDelegate.graceTask`.
    private(set) var accessTask: Task<Void, Never>?

    var onSummary: ((DownloadSummary?) -> Void)?
    var onCompleted: ((DownloadCompletion) -> Void)?
    var onAccess: ((DownloadsAccess) -> Void)?

    init(
        folder: URL,
        source: DownloadProgressSource,
        probeAccess: @escaping AccessProbe = DownloadsController.readsFolder,
        fileExists: @escaping (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) {
        self.folder = folder
        self.source = source
        self.probeAccess = probeAccess
        self.fileExists = fileExists
    }

    /// The real probe: list the folder on a background thread. While macOS
    /// shows its prompt the read waits for the answer, which is why it is not
    /// on the main thread. A refusal — or a folder that is not there — throws.
    static let readsFolder: AccessProbe = { folder in
        await Task.detached(priority: .userInitiated) {
            (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil
            )) != nil
        }.value
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if enabled { checkAccessAndSubscribe() } else { stop() }
    }

    /// Asks again after a refusal — when Settings is shown, the moment the
    /// person may have just changed their mind in System Settings. Does
    /// nothing unless the module is on and was refused, so presenting
    /// Settings reads no folder otherwise.
    func recheckAccess() {
        guard isEnabled, access == .denied else { return }
        checkAccessAndSubscribe()
    }

    private func checkAccessAndSubscribe() {
        guard isEnabled, !isSubscribed, accessTask == nil else { return }
        let folder = self.folder
        let probe = probeAccess
        accessTask = Task { [weak self] in
            let granted = await probe(folder)
            guard let self else { return }
            self.accessTask = nil
            // Switched off while macOS was asking: the answer is kept for
            // nobody, and nothing subscribes.
            guard self.isEnabled, !Task.isCancelled else { return }
            self.setAccess(granted ? .granted : .denied)
            if granted { self.subscribe() }
        }
    }

    private func subscribe() {
        isSubscribed = true
        source.start(watching: folder) { [weak self] event in
            self?.handle(event)
        }
    }

    /// One event from the source. Internal so a test can drive the real
    /// path; the fake source calls it the same way the real one does.
    func handle(_ event: DownloadEvent) {
        // A callback that arrives after `stop()` publishes nothing: the
        // subscription is gone as far as anyone looking can tell.
        guard isSubscribed else { return }
        let before = tracker.summary
        let completion = tracker.apply(event, finalFileExists: fileExists)
        let after = tracker.summary
        // The completion first: a progress peek under the pointer then
        // becomes the completion peek in one step, where publishing the
        // emptied summary first would close it and reopen it a moment later.
        if let completion, isActive { onCompleted?(completion) }
        // Equal summaries are the same ring, so they are not republished --
        // `DownloadSummary` is quantised to whole percents for this.
        if after != before { onSummary?(after) }
    }

    func setActivity(_ activity: SystemActivity) {
        isActive = activity == .active
    }

    /// Stops everything: the pending check, the subscription, what was
    /// tracked, and the badge. Also what quitting calls.
    func stop() {
        accessTask?.cancel()
        accessTask = nil
        if isSubscribed {
            source.stop()
            isSubscribed = false
        }
        let hadSummary = tracker.summary != nil
        tracker.reset()
        if hadSummary { onSummary?(nil) }
        setAccess(.unknown)
    }

    private func setAccess(_ next: DownloadsAccess) {
        guard next != access else { return }
        access = next
        onAccess?(next)
    }
}
