import CreativeNotchCore

/// Where `PowerController`'s snapshots come from.
///
/// A seam like `BluetoothSource` (2026-10-28): the delegate holds
/// `SandboxPowerObserver`, which reads nothing, and only
/// `configureForRealLaunch()` hands it the IOKit `PowerObserver`.
///
/// **Why.** The delegate used to build the real observer at `install`, so
/// every suite that called `startSubsystems()` read the Mac it ran on. Below
/// 20% and discharging, the first snapshot is a `.lowBattery` peek, which
/// widens the closed notch's accepted region to 370pt -- and
/// `ModuleToggleTests.disablingMediaNarrowsTheClosedNotchBackToItsBareWidth`
/// failed on `main` for as long as the battery stayed low. Every power
/// decision is reachable without it through `PowerController.apply` and
/// `AppDelegate.powerDidChange`.
@MainActor
protocol PowerStateObserver: AnyObject {
    var onChange: ((PowerSnapshot) -> Void)? { get set }
    /// Whether this Mac has an internal battery, as of the last `start()`.
    var hasBattery: Bool { get }
    /// Whether `start()` has registered and `stop()` has not yet undone it.
    var isObserving: Bool { get }
    func start()
    func stop()
}

/// The default: registers with nothing, reads nothing, publishes nothing.
///
/// It still answers `isObserving`, so the switchboard's start and stop of
/// the power module stay provable without reaching IOKit.
final class SandboxPowerObserver: PowerStateObserver {
    var onChange: ((PowerSnapshot) -> Void)?
    var hasBattery: Bool { false }
    private(set) var isObserving = false

    init() {}

    func start() { isObserving = true }
    func stop() { isObserving = false }
}
