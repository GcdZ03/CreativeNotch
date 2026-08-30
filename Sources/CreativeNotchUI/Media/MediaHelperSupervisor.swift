import Dispatch
import Foundation
import CreativeNotchCore

/// Restarts the media helper when it dies, and gives up after
/// `HelperBackoff.maxAttempts`.
///
/// The helper is a subprocess talking to a private Apple framework, so it
/// failing is ordinary rather than exceptional. Retrying forever would be
/// a crash loop nobody notices, burning power for a capability the user is
/// not getting — the media TRANSPORT controls (play/pause/next/previous)
/// are a separate, already-shipped module that needs none of this and
/// keep working regardless. Only the now-playing header and peek are
/// lost when this degrades.
///
/// `startHelper`, `stopHelper`, and `scheduleRetry` are injected — the
/// same shape as `ClipboardPoller`'s injected timer — so tests capture
/// what was *asked for* and invoke the pending retry directly. Nothing
/// here sleeps, spawns, or touches a real clock; the default
/// `scheduleRetry` uses a one-shot `DispatchQueue.main.asyncAfter`, which
/// is not a repeating timer and so does not violate the one-timer rule
/// (that's `ClipboardPoller`'s).
@MainActor
public final class MediaHelperSupervisor {

    public var onLine: ((String) -> Void)?
    public var onDegraded: (() -> Void)?

    public var startHelper: () -> Void
    public var stopHelper: () -> Void

    /// Injected so tests can assert what was *asked* for without waiting.
    /// The work closure is `@MainActor` for the same reason
    /// `ClipboardPoller.scheduleTimer`'s fire closure is: it must be
    /// `Sendable` to cross into `DispatchQueue.main.asyncAfter`, and a
    /// global-actor-isolated closure is `Sendable` where a bare
    /// main-actor one is not.
    public var scheduleRetry: (TimeInterval, @escaping @MainActor () -> Void) -> Void

    public private(set) var attempt = 0
    public private(set) var isDegraded = false

    /// Set by `stop()` so the exit that follows is recognized as
    /// deliberate rather than a crash.
    ///
    /// This flag, not the exit status, is the authority on "did the
    /// parent ask for this". The bridge (task 6) exits with status 0 on
    /// a genuine stdout I/O failure — the same status a clean shutdown
    /// produces — so status alone cannot distinguish "the parent asked
    /// me to stop" from "my stdout broke". Without this flag, a helper
    /// whose pipe breaks would look like a clean shutdown and never be
    /// restarted, silently killing the now-playing feature until the
    /// app relaunches.
    private var stoppedDeliberately = false

    private let helperProcess: MediaHelperProcess?

    public init() {
        let process = MediaHelperProcess()
        self.helperProcess = process
        self.startHelper = { [weak process] in process?.start() }
        self.stopHelper = { [weak process] in process?.stop() }
        self.scheduleRetry = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated { work() }
            }
        }

        process.onLine = { [weak self] line in self?.onLine?(line) }
        process.onExit = { [weak self] status in self?.helperExited(status: status) }
    }

    public func start() {
        stoppedDeliberately = false
        startHelper()
    }

    public func stop() {
        // Recorded before calling out: the exit callback this triggers
        // (directly, in tests, or via the wrapped process's own
        // termination handler) must see it already set.
        stoppedDeliberately = true
        stopHelper()
    }

    /// The helper produced a line, so it is healthy — a long-lived helper
    /// dying much later is not the fifth failure of a crash loop, and
    /// should get a fresh attempt budget rather than tripping the cap.
    public func noteHealthy() {
        attempt = 0
    }

    /// Called when the underlying helper process exits, whether that was
    /// asked for or not.
    public func helperExited(status: Int32) {
        guard !stoppedDeliberately else { return }
        guard !isDegraded else { return }

        attempt += 1
        guard let delay = HelperBackoff.delay(forAttempt: attempt) else {
            // `delay(forAttempt:)` returning `nil` means degrade, not
            // "retry immediately" — never schedule again once this
            // fires.
            isDegraded = true
            onDegraded?()
            return
        }

        scheduleRetry(delay) { [weak self] in
            self?.startHelper()
        }
    }
}
