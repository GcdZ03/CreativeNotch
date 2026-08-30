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

    /// Injected the same way `AppDelegate.now` and `ClipboardPoller`'s
    /// `isLowPowerMode` are: a closure rather than a parameter threaded
    /// through `start()`/`noteHealthy()`, because those two must keep
    /// their existing call sites (`MediaController` and `AppDelegate`
    /// call them with no `now:` argument) and because `noteHealthy()`
    /// needs to compare against a spawn time recorded by an *earlier*
    /// call, not one passed in by its own caller. Tests replace this to
    /// move time without sleeping; nothing here reads `Date()` directly.
    public var now: () -> TimeInterval = { Date().timeIntervalSince1970 }

    public private(set) var attempt = 0
    public private(set) var isDegraded = false

    /// When the currently-running helper was (re)started, per `now()`.
    /// `nil` until the first `startHelper()` call. Used by `noteHealthy()`
    /// to turn "a line arrived" into "the helper has been up long enough
    /// to matter" — see that method's doc comment.
    private var startedAt: TimeInterval?

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

    /// Bumped by every `stop()`. A retry closure captures the generation
    /// current at the moment it was scheduled and checks it again before
    /// acting, so a `stop()` that lands while a retry is still pending
    /// invalidates it.
    ///
    /// Without this, a retry scheduled before `stop()` fires later
    /// anyway and calls `startHelper()` directly — resurrecting the
    /// helper against an explicit stop. Worse, because that path
    /// bypasses `start()`, `stoppedDeliberately` is never reset back to
    /// `false`, so the NEXT real crash of that resurrected helper is
    /// then silently swallowed as if it were another deliberate stop,
    /// never restarted. Do not remove this as redundant with
    /// `stoppedDeliberately` — that flag alone stops a *new* exit from
    /// being misread, but does nothing about a retry already in flight.
    private var retryGeneration = 0

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
        startedAt = now()
        startHelper()
    }

    public func stop() {
        // Recorded before calling out: the exit callback this triggers
        // (directly, in tests, or via the wrapped process's own
        // termination handler) must see it already set.
        stoppedDeliberately = true
        // Invalidates any retry scheduled before this call — see
        // `retryGeneration`'s doc comment for why a pending retry must
        // not be allowed to outlive a stop.
        retryGeneration += 1
        stopHelper()
    }

    /// The helper produced a line — but a line alone does not mean
    /// "healthy". Two failure modes sit on either side of this method and
    /// neither is correct:
    ///
    /// - Latching "healthy" once for the controller's whole lifetime (the
    ///   original bug) meant a long-lived helper that crashed once, early,
    ///   never got the budget back — five crashes spread across five days
    ///   looked identical to five crashes in five seconds, and degraded a
    ///   perfectly fine module.
    /// - Resetting on *any* line (the regression this replaces) is worse:
    ///   `bridge.m` emits one line immediately on spawn, so a helper that
    ///   emits its startup line and then dies immediately resets the
    ///   budget every single time — spawn, emit, crash, wait, spawn, emit,
    ///   crash, forever. `HelperBackoff.maxAttempts` becomes unreachable
    ///   and the crash loop this whole module exists to stop from burning
    ///   power runs undetected.
    ///
    /// The fix is a DURATION notion of healthy: the helper earns a fresh
    /// budget only once it has stayed up longer than the backoff delay
    /// that was spent waiting for it — i.e. `HelperBackoff.delay(forAttempt:
    /// attempt)`, the same delay `helperExited(status:)` used to schedule
    /// this very spawn. That is strictly longer than the near-instant gap
    /// between spawn and the startup line, so a crash-loop line can never
    /// pass it, while a helper that genuinely runs for a while still does.
    /// When there is no such delay (`attempt == 0`, nothing has failed
    /// yet) there is nothing to protect against, so this resets
    /// unconditionally — the same no-op it always was in that case.
    public func noteHealthy() {
        guard let startedAt, let requiredUptime = HelperBackoff.delay(forAttempt: attempt) else {
            attempt = 0
            return
        }
        guard now() - startedAt > requiredUptime else { return }
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

        let generation = retryGeneration
        scheduleRetry(delay) { [weak self] in
            guard let self, self.retryGeneration == generation else { return }
            // Recorded here, not just in `start()`: `noteHealthy()` measures
            // uptime of the CURRENT spawn, and a retry restarts the helper
            // without going through `start()`.
            self.startedAt = self.now()
            self.startHelper()
        }
    }
}
