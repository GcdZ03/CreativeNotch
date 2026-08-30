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
/// on *estimate drift*, not only on plug and unplug — 43 times in 39
/// minutes on a machine sitting still on battery.
///
/// Since the time-remaining estimate was removed, that drift is no longer
/// part of the snapshot, so `read()` drops nearly all of those callbacks
/// as carrying nothing new. What used to be the noisiest field is now
/// simply not read, and the module wakes its consumers only when the level,
/// the source, the charging state or Low Power Mode actually changes.
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
        // Absent means not charged, which is Apple's own convention: the
        // key is published where it is meaningful and omitted otherwise —
        // it is not in the dictionary at all while running on battery.
        //
        // `IOPSKeys.h` also documents the state that made this necessary,
        // in as many words: "a battery may validly be plugged in, not
        // charging, and <100% charge", and "a battery with capacity >= 95%
        // and not charging is defined as charged". So charged is not the
        // negation of charging, and 100% is not the threshold.
        let charged = description[kIOPSIsChargedKey] as? Bool ?? false


        return PowerSnapshot(
            level: Int((Double(current) / Double(maximum) * 100).rounded()),
            source: source,
            isCharging: charging,
            isCharged: charged,
            isLowPowerMode: isLowPowerMode
        )
    }
}
