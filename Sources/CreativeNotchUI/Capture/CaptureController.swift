import AppKit
import CreativeNotchCore

/// Turns capture readings into what the notch shows.
///
/// **It is not suspended by the activity gate**, and that is deliberate — the
/// same shape as the power module. The observer is notification-driven, so it
/// costs nothing idle, and suspending it would mean missing a capture starting
/// while the screen was locked and then reporting the wrong thing on unlock.
/// What the gate suppresses here is nothing at all: the badge is ambient, not
/// a peek, so there is no interruption to withhold.
@MainActor
final class CaptureController {

    /// Internal rather than private, for the same reason `ClipboardController
    /// .poller` and `MediaController.supervisor` are: a suite that could not
    /// reach this would be reading the developer's actual microphone, and
    /// would pass or fail depending on whether they happened to be on a call.
    let observer: CaptureObserver
    private var debounce = CaptureDebounce()
    private var isEnabled = true

    /// Published whenever the indicator should change. Only on a genuine
    /// change: `CaptureDebounce` exists because CoreMediaIO fires three events
    /// per camera start.
    var onChange: ((CaptureUse) -> Void)?

    private(set) var use: CaptureUse = .none

    init(observer: CaptureObserver = CaptureObserver()) {
        self.observer = observer
        self.observer.onChange = { [weak self] reading in
            self?.apply(reading)
        }
    }

    var isObserving: Bool { observer.registrationCount > 0 }

    func start() {
        guard isEnabled else { return }
        observer.start()
    }

    func stop() {
        observer.stop()
        // Publish the absence. Stopping the observer stops producing readings;
        // it does not remove the badge already on screen, and a privacy tell
        // stuck on after its module was switched off is worse than none.
        apply(.none, force: true)
    }

    /// Only ever called by `ModuleSwitchboard`. The latch exists as well as
    /// the switchboard for the reason `MediaController`'s does: it makes the
    /// controller safe to call by somebody who has not read the switchboard.
    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if enabled { start() } else { stop() }
    }

    private func apply(_ reading: CaptureUse, force: Bool = false) {
        if force {
            debounce = CaptureDebounce(initial: reading)
            use = reading
            onChange?(reading)
            return
        }
        guard let changed = debounce.accept(reading) else { return }
        use = changed
        onChange?(changed)
    }
}
