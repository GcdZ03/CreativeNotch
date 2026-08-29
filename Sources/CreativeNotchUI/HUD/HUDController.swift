import AppKit
import CreativeNotchCore

/// Owns the HUD's decision path: coalesce, attribute, then peek.
///
/// The observers and the key monitor are dumb sources; every judgement
/// happens here, against pure logic from `CreativeNotchCore`, so it is
/// testable without hardware.
@MainActor
public final class HUDController {

    private var coalescer = HUDCoalescer()
    private var significanceGate = HUDSignificanceGate()
    private var lastKeyAt: TimeInterval?

    private let onPeek: (HUDKind) -> Void

    /// Internal rather than private so the lifecycle is provable: a
    /// `stop()` that silently forgot one of the three would otherwise pass
    /// review the same way the mismatched `stop()`s in `VolumeObserver`,
    /// `BrightnessObserver` and `MediaKeyMonitor` did before their own
    /// identity-based tests existed.
    let volume = VolumeObserver()
    let brightness = BrightnessObserver()
    let keys = MediaKeyMonitor()

    public init(onPeek: @escaping (HUDKind) -> Void) {
        self.onPeek = onPeek
    }

    public func start() {
        volume.onChange = { [weak self] kind in
            self?.handle(kind, at: Date().timeIntervalSince1970)
        }
        brightness.onChange = { [weak self] kind in
            self?.handle(kind, at: Date().timeIntervalSince1970)
        }
        keys.onKey = { [weak self] in
            self?.noteKeyPress(at: Date().timeIntervalSince1970)
        }
        volume.start()
        brightness.start()
        keys.start()

        // Prime the noise-floor baseline with the levels already in
        // effect. Without this the first event after launch has nothing to
        // be measured against, is treated as the first thing ever seen,
        // and pops a HUD for ambient drift that was already under way —
        // which is precisely the startup flicker this module must not have.
        if let level = brightness.currentLevel() {
            noteBaseline(.brightness(level))
            diagnostics?.record("primed brightness baseline at \(level)")
        } else {
            diagnostics?.record("could NOT prime brightness baseline (currentLevel was nil)")
        }
        if let level = volume.currentLevel() {
            noteBaseline(.volume(level))
            diagnostics?.record("primed volume baseline at \(level)")
        } else {
            diagnostics?.record("could NOT prime volume baseline (currentLevel was nil)")
        }
        if let muted = volume.isMuted() {
            noteBaseline(.mute(muted))
            diagnostics?.record("primed mute baseline at \(muted)")
        }
    }

    /// Records a value as already-seen without showing anything, so the
    /// next event is measured against reality rather than against nothing.
    ///
    /// Mute takes the other path deliberately: it has no magnitude and so
    /// no noise-floor baseline, and what must not repeat is the *shown*
    /// state — otherwise the first mute callback after launch pops a HUD
    /// for a state that has not changed.
    public func noteBaseline(_ kind: HUDKind) {
        if case .mute = kind {
            significanceGate.commitShown(kind)
        } else {
            significanceGate.commitObserved(kind)
        }
    }

    public func stop() {
        volume.stop()
        brightness.stop()
        keys.stop()
    }

    public func noteKeyPress(at time: TimeInterval) {
        lastKeyAt = time
        diagnostics?.record("key pressed")
    }

    /// Opt-in decision log, for working out why a peek appeared when
    /// nobody touched anything.
    ///
    /// Off unless explicitly enabled, and it writes only when the HUD path
    /// actually runs — so it costs nothing in a normal session:
    ///
    ///     defaults write com.gcdz.creativenotch HUDDiagnostics -bool YES
    ///
    /// Log: ~/Library/Logs/CreativeNotch-hud.log
    let diagnostics = HUDDiagnostics.enabledFromDefaults()

    /// Time is a parameter, not a clock read, so the whole path is testable.
    public func handle(_ kind: HUDKind, at time: TimeInterval) {
        diagnostics?.record("event \(kind)")
        // Duplicates first: CoreAudio fires twice per change, and letting
        // both through flickers the pill and restarts the peek TTL twice.
        guard coalescer.accept(kind, at: time) else {
            diagnostics?.record("  dropped: duplicate within \(HUDCoalescer.minimumInterval)s")
            return
        }

        // Then the noise floor: the ambient light sensor does not jitter,
        // it *ramps* — bursts of ~58 events a second that move the
        // backlight as fast as a slider drag does. Because the
        // significance gate below compares against the last value shown,
        // that ramp accumulates past the threshold on its own and pops a
        // HUD nobody asked for: 8 of them in one measured session with
        // nothing touched. Rate cannot separate ambient from deliberate;
        // per-event step size can.
        //
        // Observed is committed for every event, filtered or not. Skipping
        // it here would let drift accumulate against a stale baseline and
        // cross the floor anyway.
        let aboveFloor = significanceGate.isAboveNoiseFloor(kind)
        significanceGate.commitObserved(kind)
        guard aboveFloor else {
            diagnostics?.record("  dropped: under the noise floor (ambient sensor)")
            return
        }

        // Then significance, which lets a series of small *deliberate*
        // steps accumulate until they are worth showing.
        guard significanceGate.isSignificant(kind) else {
            diagnostics?.record("  dropped: too small a change since the last one shown")
            return
        }

        // Apple's HUD already covers keypresses. Everywhere else, macOS
        // gives no feedback at all — that is the gap this fills.
        //
        // The baseline is committed only here, once every filter has run
        // and the value is actually about to be shown. Committing on mere
        // significance would advance the baseline for a keypress-driven
        // change this suppresses, and a later genuine external change
        // within the threshold of that phantom baseline would be silently
        // dropped even though it never appeared on screen.
        guard !HUDAttribution.isKeyDriven(changeAt: time, lastKeyAt: lastKeyAt) else {
            diagnostics?.record("  dropped: attributed to a keypress, Apple's HUD covers it")
            return
        }
        significanceGate.commitShown(kind)

        diagnostics?.record("  SHOWN")
        onPeek(kind)
    }
}
