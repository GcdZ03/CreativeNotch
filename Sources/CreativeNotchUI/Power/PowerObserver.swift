import AppKit
import IOKit.ps
import CreativeNotchCore

/// Turns IOKit power-source notifications and
/// `processInfoPowerStateDidChange` into a `PowerSnapshot`.
///
/// A dumb source, like `SystemActivityObserver` and the HUD's observers:
/// every judgement — whether an estimate is trustworthy, whether a
/// threshold has been crossed, whether anything should be shown — lives
/// above this in Core, where it runs headlessly. This file knows about
/// `CFDictionary`, and nothing else in the project does.
///
/// The module needs no timer. `IOPSNotificationCreateRunLoopSource` fires
/// on power-source change and the notification centre covers Low Power
/// Mode, so a registered-and-idle observer costs nothing — which is what
/// the one rule actually asks for.
///
/// Note what the calibration probe measured: the IOKit notification fires
/// on *estimate drift*, not only on plug and unplug — fourteen times in
/// eighteen minutes on a machine sitting still on battery. Nothing here
/// filters that. `read()` drops callbacks that carry no change at all,
/// `PowerController` decides what is worth speaking about, and
/// `BatteryEstimateGate` decides what is worth believing.
@MainActor
public final class PowerObserver {

    public var onChange: ((PowerSnapshot) -> Void)?

    public private(set) var snapshot: PowerSnapshot?

    /// Whether this Mac has an internal battery at all.
    ///
    /// Read once, at `start()`. A machine does not grow a battery.
    public private(set) var hasBattery: Bool = false

    private var source: CFRunLoopSource?
    private var lowPowerToken: NSObjectProtocol?

    /// Internal rather than private so the lifecycle is provable.
    ///
    /// `VolumeObserver`, `BrightnessObserver` and `MediaKeyMonitor` each
    /// shipped a `stop()` that forgot one of the things `start()`
    /// registered, and every one was caught by a count like this rather
    /// than by reading the code. This observer registers two different
    /// *kinds* of thing — a `CFRunLoopSource` and a notification token —
    /// which is exactly the asymmetry that produced those bugs.
    var registrationCount: Int {
        (source == nil ? 0 : 1) + (lowPowerToken == nil ? 0 : 1)
    }

    /// The run-loop source, so a test can ask the run loop itself whether
    /// it is still installed.
    ///
    /// `registrationCount` above is not enough on its own and the first
    /// draft of this file proved it: a `stop()` that nils the field
    /// without removing the source, and a `start()` that installs a
    /// second source over the first, both leave the count correct. Only
    /// the run loop knows the truth.
    var runLoopSource: CFRunLoopSource? { source }

    /// How many times a registered notification has driven a read.
    ///
    /// Here for the same reason: a leaked notification observer is
    /// invisible to a field count and obvious in a delivery count.
    private(set) var readCount = 0

    public init() {}

    public func start() {
        // Re-registering must not stack: `start()` twice is a wiring
        // mistake, not a reason to receive every event twice.
        stop()

        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let observer = Unmanaged<PowerObserver>.fromOpaque(context)
                .takeUnretainedValue()
            // The source was added to the main run loop, so the callback
            // arrives on the main thread. Unretained, so `stop()` must run
            // before this object dies — the lifecycle is owned by
            // `AppDelegate`, as every other observer's is.
            MainActor.assumeIsolated { observer.read() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            self.source = source
        }

        lowPowerToken = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.read() }
        }

        read()
        hasBattery = snapshot != nil
    }

    public func stop() {
        if let source {
            // Removed from the same run loop and the same mode it was
            // added to. Removing from the wrong one silently does
            // nothing — the same trap `SystemActivityObserver` documents
            // for distributed notification centres.
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            self.source = nil
        }

        if let lowPowerToken {
            NotificationCenter.default.removeObserver(lowPowerToken)
            self.lowPowerToken = nil
        }
    }

    /// Reads the current state and publishes it if it changed.
    ///
    /// Only changes are reported. The probe measured the notification
    /// firing while the machine sat still, and a consumer that rebuilt
    /// state on every callback would do so for events carrying nothing.
    func read() {
        readCount += 1
        guard let next = Self.currentSnapshot() else { return }
        guard next != snapshot else { return }
        snapshot = next
        onChange?(next)
    }

    /// The current internal battery, or `nil` if this Mac has none.
    static func currentSnapshot() -> PowerSnapshot? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue()
                as? [CFTypeRef]
        else { return nil }

        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

        for entry in list {
            guard let description = IOPSGetPowerSourceDescription(blob, entry)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            if let snapshot = snapshot(from: description, isLowPowerMode: lowPower) {
                return snapshot
            }
        }
        return nil
    }

    /// Converts one IOKit power source description.
    ///
    /// Static and internal so the whole conversion is testable against
    /// dictionaries, on any machine, without a battery or a charger being
    /// moved by hand.
    ///
    /// Returns `nil` for anything that is not this Mac's own battery.
    static func snapshot(
        from description: [String: Any],
        isLowPowerMode: Bool
    ) -> PowerSnapshot? {
        guard (description[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType
        else { return nil }

        guard let current = description[kIOPSCurrentCapacityKey] as? Int,
              let maximum = description[kIOPSMaxCapacityKey] as? Int,
              maximum > 0
        else { return nil }

        let state = description[kIOPSPowerSourceStateKey] as? String
        // Anything unrecognised is battery. Guessing the other way tells
        // somebody running on reserve that they are plugged in.
        let source: PowerSource = (state == kIOPSACPowerValue) ? .wall : .battery

        let charging = description[kIOPSIsChargingKey] as? Bool ?? false

        // On wall power IOKit publishes time-to-full instead of
        // time-to-empty; the panel shows whichever applies. `-1` is
        // "Still Calculating" (`IOPSKeys.h`), and every negative value is
        // treated the same way — a sentinel that changes shape in a
        // future macOS must not become a negative duration on screen.
        //
        // The charging key has a *second* not-applicable convention, and
        // it is not negative. Plugged in with nothing charging, IOKit
        // reports `Time to Full Charge = 0`, meaning "not applicable" —
        // measured on a real machine at 55% with the charger attached.
        // Filtering only negatives let that through as a real estimate and
        // the panel read "Until full: 0 min".
        //
        // Zero cannot simply be rejected everywhere: zero minutes *to
        // empty* is a legitimate and rather important reading. It is the
        // charging key specifically that is meaningless when nothing is
        // charging, so the guard is on the state, not on the value.
        let estimate: Int?
        if source == .wall {
            let raw = charging ? description[kIOPSTimeToFullChargeKey] as? Int : nil
            estimate = (raw ?? -1) >= 0 ? raw : nil
        } else {
            let raw = description[kIOPSTimeToEmptyKey] as? Int
            estimate = (raw ?? -1) >= 0 ? raw : nil
        }

        return PowerSnapshot(
            level: Int((Double(current) / Double(maximum) * 100).rounded()),
            source: source,
            isCharging: charging,
            estimateMinutes: estimate,
            isLowPowerMode: isLowPowerMode
        )
    }
}
