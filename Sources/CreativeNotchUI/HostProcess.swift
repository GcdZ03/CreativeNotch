import Foundation

/// What kind of process this code is running in (2026-10-17).
///
/// Side effects that reach real hardware — the haptic engine, the camera —
/// belong to the packaged app only. `swift test` and `swift run` run the same
/// code from a bare executable, and the suite must never tap the trackpad or
/// switch the camera on, whether or not each test remembered to stub it.
enum HostProcess {
    /// Whether `bundle` is a packaged `.app` — `dist/CreativeNotch.app` or an
    /// installed copy — rather than a bare executable or a test runner.
    static func isPackagedApp(_ bundle: Bundle = .main) -> Bool {
        bundle.bundleURL.pathExtension == "app"
    }
}
