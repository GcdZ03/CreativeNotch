import Foundation
import CreativeNotchCore

/// Owns the live countdowns and the single outstanding one-shot.
///
/// There is never a repeating timer here. Each wake reschedules the next
/// one from `TimerSchedule`, so a 25-minute countdown costs 25 wakes in its
/// first 24 minutes rather than 1,500 — the clipboard poller stays the only
/// repeating thing in the project.
///
/// **Several countdowns, still one wake (2026-10-24).** Up to
/// `TimerSet.capacity` run at once, and there is still exactly one
/// outstanding one-shot: `TimerSet.nextWake` is the earliest member's own
/// `TimerSchedule` answer, and every change cancels and replaces it. A
/// timer per countdown would be three schedules waking independently; this
/// is one, aimed at whichever countdown next needs a redraw or a
/// completion. Starting a preset with none running behaves exactly as it
/// did when one countdown was the whole model.
@MainActor
final class TimerController {

    /// Every running or paused countdown, in start order.
    private(set) var timers = TimerSet()

    /// The countdown the ear shows: the soonest to finish
    /// (`TimerSet.soonest`). What `onChange` publishes.
    var countdown: Countdown? { timers.soonest(at: now()) }

    /// The delay of the outstanding one-shot, or `nil` when nothing is
    /// scheduled. Recorded synchronously as the task is spawned.
    ///
    /// This is the only synchronous view of what the controller decided to
    /// do. Without it the controller's scheduling could only be observed by
    /// waiting for the one-shot to fire, and a test that waits on real time
    /// is a test that flakes — so the spec's claim that a paused timer
    /// costs zero redraws would have nothing asserting it at this layer.
    private(set) var scheduledWake: TimeInterval?

    /// Fires whenever the countdowns change and the UI should redraw, with
    /// the soonest. The whole list is `timers`, read in the same breath.
    var onChange: ((Countdown?) -> Void)?

    /// Fires once per countdown, when its deadline passes.
    var onFinished: ((Countdown) -> Void)?

    /// Injected so tests can drive the whole lifecycle by passing
    /// timestamps, exactly as `PeekArbiter` and `ShelfStore` do.
    private let now: () -> Date

    /// The outstanding one-shot. There is at most one, ever — however many
    /// countdowns are running.
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

    /// Adds a countdown. With none running this is the single timer it
    /// always was; with some running it starts beside them, and at
    /// `TimerSet.capacity` it is refused rather than replacing one.
    func start(duration: TimeInterval) {
        guard timers.add(duration: duration, at: now()) != nil else { return }
        publish()
    }

    /// The bare verbs act on every countdown. They are the switchboard's
    /// (quitting cancels all of them, not the soonest) and the shape the
    /// single-timer path always had; the tab's rows use the `id:` forms.
    func pause() {
        guard timers.all.contains(where: { !$0.countdown.isPaused }) else { return }
        timers.pauseAll(at: now())
        publish()
    }

    func resume() {
        guard timers.all.contains(where: { $0.countdown.isPaused }) else { return }
        timers.resumeAll(at: now())
        publish()
    }

    func cancel() {
        timers.removeAll()
        publish()
    }

    func pause(id: Int) {
        guard let timer = timers.timer(id), !timer.countdown.isPaused else { return }
        timers.pause(id: id, at: now())
        publish()
    }

    func resume(id: Int) {
        guard let timer = timers.timer(id), timer.countdown.isPaused else { return }
        timers.resume(id: id, at: now())
        publish()
    }

    func cancel(id: Int) {
        guard timers.timer(id) != nil else { return }
        timers.remove(id: id)
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

        // The deadline is decided by the clock, not by the one-shot having
        // fired: every countdown found past it completes here, each with
        // its own `onFinished`, in the order they finished — and the rest
        // carry on.
        let finished = timers.removeFinished(at: now())
        if !finished.isEmpty {
            for countdown in finished { onFinished?(countdown) }
            onChange?(countdown)
        }

        guard let delay = timers.nextWake(isActive: isActive, at: now()) else { return }

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
