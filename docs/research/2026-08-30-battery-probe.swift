// Throwaway calibration probe. NOT shipped code.
//
// Two questions:
//   1. Does IOPSNotificationCreateRunLoopSource fire on plug/unplug, and
//      how many times per transition? (the coalescing question)
//   2. How wildly does the time-remaining estimate swing after a
//      transition, and how long until it settles? (the settling +
//      agreement-tolerance numbers)
//
// The 5s timer is polling, which the shipped module will not do. It is
// here because characterising noise *between* notifications is exactly
// what the notifications do not tell us.

import Foundation
import IOKit.ps

let start = Date()

func stamp() -> String {
    String(format: "%8.1f", Date().timeIntervalSince(start))
}

func sample(_ tag: String) {
    guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
    else { print("\(stamp()) \(tag) NO-BLOB"); return }

    for ps in list {
        guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue()
                as? [String: Any] else { continue }
        guard (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }

        let cur    = d[kIOPSCurrentCapacityKey] as? Int ?? -1
        let max    = d[kIOPSMaxCapacityKey] as? Int ?? -1
        let state  = d[kIOPSPowerSourceStateKey] as? String ?? "?"
        let toEmpty = d[kIOPSTimeToEmptyKey] as? Int ?? -999
        let toFull  = d[kIOPSTimeToFullChargeKey] as? Int ?? -999
        let charging = d[kIOPSIsChargingKey] as? Bool ?? false
        let charged  = d[kIOPSIsChargedKey] as? Bool ?? false
        let lpm = ProcessInfo.processInfo.isLowPowerModeEnabled

        // -1 is kIOPSTimeRemainingUnknownValue's shape in the dict form.
        print("\(stamp()) \(tag) pct=\(cur)/\(max) state=\(state) charging=\(charging) charged=\(charged) toEmpty=\(toEmpty) toFull=\(toFull) lpm=\(lpm)")
        fflush(stdout)
    }
}

// The exact callback the shipped observer will use.
let source = IOPSNotificationCreateRunLoopSource({ _ in
    sample("NOTIFY")
}, nil).takeRetainedValue()
CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)

// Low Power Mode arrives separately, per the roadmap.
NotificationCenter.default.addObserver(
    forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
) { _ in sample("LPM") }

Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in sample("TICK") }

sample("START")
print("# probe running — unplug and replug the charger a few times")
fflush(stdout)
CFRunLoopRun()
