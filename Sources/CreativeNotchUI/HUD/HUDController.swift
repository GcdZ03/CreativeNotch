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
    private var lastKeyAt: TimeInterval?

    private let onPeek: (HUDKind) -> Void

    private let volume = VolumeObserver()
    private let brightness = BrightnessObserver()
    private let keys = MediaKeyMonitor()

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
    }

    public func stop() {
        volume.stop()
        brightness.stop()
        keys.stop()
    }

    public func noteKeyPress(at time: TimeInterval) {
        lastKeyAt = time
    }

    /// Time is a parameter, not a clock read, so the whole path is testable.
    public func handle(_ kind: HUDKind, at time: TimeInterval) {
        // Duplicates first: CoreAudio fires twice per change, and letting
        // both through flickers the pill and restarts the peek TTL twice.
        guard coalescer.accept(kind, at: time) else { return }

        // Apple's HUD already covers keypresses. Everywhere else, macOS
        // gives no feedback at all — that is the gap this fills.
        guard !HUDAttribution.isKeyDriven(changeAt: time, lastKeyAt: lastKeyAt) else { return }

        onPeek(kind)
    }
}
