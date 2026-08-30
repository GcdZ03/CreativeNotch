import Foundation
import CreativeNotchCore

/// Owns the live countdown and the single outstanding one-shot.
///
/// There is never a repeating timer here. Each wake reschedules the next
/// one from `TimerSchedule`, so a 25-minute countdown costs 25 wakes in its
/// first 24 minutes rather than 1,500 — the clipboard poller stays the only
/// repeating thing in the project.
@MainActor
final class TimerController {

    private(set) var countdown: Countdown?

    /// The delay of the outstanding one-shot, or `nil` when nothing is
    /// scheduled. Recorded synchronously as the task is spawned.
    ///
    /// This is the only synchronous view of what the controller decided to
    /// do. Without it the controller's scheduling could only be observed by
    /// waiting for the one-shot to fire, and a test that waits on real time
    /// is a test that flakes — so the spec's claim that a paused timer
    /// costs zero redraws would have nothing asserting it at this layer.
    private(set) var scheduledWake: TimeInterval?

    /// Fires whenever the countdown value changes and the UI should redraw.
    var onChange: ((Countdown?) -> Void)?

    /// Fires once, when the deadline passes.
    var onFinished: ((Countdown) -> Void)?

    /// Injected so tests can drive the whole lifecycle by passing
    /// timestamps, exactly as `PeekArbiter` and `ShelfStore` do.
    private let now: () -> Date

    /// The outstanding one-shot. There is at most one, ever.
    ///
    /// Readable rather than private so that `reschedulingCancelsThe
    /// OutstandingWake` can prove it: `Task.cancel()` sets `isCancelled`
    /// synchronously, which is the only way to show that rescheduling
    /// *replaces* the wake instead of leaving a second chain running
    /// beside it — without that cancel, every activity flip would fork
    /// another chain and double the wake rate, which is the exact cost
    /// this module exists to avoid.
    private(set) var pending: Task<Void, Never>?

    private var isActive = true

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    func start(duration: TimeInterval) {
        guard let new = Countdown(duration: duration, startingAt: now()) else { return }
        countdown = new
        publish()
    }

    func pause() {
        guard let countdown, !countdown.isPaused else { return }
        self.countdown = countdown.paused(at: now())
        publish()
    }

    func resume() {
        guard let countdown, countdown.isPaused else { return }
        self.countdown = countdown.resumed(at: now())
        publish()
    }

    func cancel() {
        countdown = nil
        publish()
    }

    /// The `SystemActivity` gate. Changing it reschedules, because the
    /// correct wake differs between awake and asleep.
    ///
    /// Note what this deliberately does *not* do: unlike
    /// `ClipboardController.setActivity` and `MediaController.setActivity`,
    /// it never stops the subsystem. A timer's whole purpose is to fire
    /// while nobody is looking, so the exemption reschedules rather than
    /// suspends.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        reschedule()
    }

    /// Recomputes the display and the schedule together. Called on every
    /// state change and on every wake.
    private func publish() {
        onChange?(countdown)
        reschedule()
    }

    private func reschedule() {
        pending?.cancel()
        pending = nil
        scheduledWake = nil

        guard let countdown else { return }

        if countdown.hasFinished(at: now()) {
            onFinished?(countdown)
            self.countdown = nil
            onChange?(nil)
            return
        }

        guard let delay = TimerSchedule.nextWake(
            countdown: countdown, isActive: isActive, at: now()
        ) else { return }

        scheduledWake = delay
        pending = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                // Cancelled, or the sleep failed. Either way this wake is
                // no longer ours to fire — `reschedule` has already run or
                // is about to. Returning rather than `try?`-ing onwards
                // keeps a failed sleep from firing the wake early.
                return
            }
            guard !Task.isCancelled else { return }
            // Re-read rather than trusting the delay: the machine may have
            // slept through it, in which case far more time has passed than
            // was scheduled and the countdown has to be recomputed from the
            // clock. This is why `Countdown` stores a target date.
            self?.publish()
        }
    }
}
