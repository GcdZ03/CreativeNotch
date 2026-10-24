import AppKit
import CoreBluetooth
import IOBluetooth
import CreativeNotchCore

/// Where connect and disconnect callbacks come from.
///
/// A protocol so the controller — and every test of it — runs on fake
/// devices: a real source needs a paired device, the Bluetooth radio and the
/// Bluetooth permission, none of which a test may touch.
@MainActor
protocol BluetoothSource: AnyObject {
    var onConnect: ((BluetoothDeviceInfo) -> Void)? { get set }
    var onDisconnect: ((BluetoothDeviceInfo) -> Void)? { get set }
    /// What is connected right now: the baseline that is not announced.
    func connectedDevices() -> [BluetoothDeviceInfo]
    func start()
    func stop()
}

/// Whether the app may use Bluetooth, and asking.
@MainActor
protocol BluetoothAccess: AnyObject {
    /// Reading it never prompts.
    var status: BluetoothAuthorization { get }
    /// Shows macOS's prompt if it has not been answered, and calls back with
    /// the answer.
    func request(_ completion: @escaping @MainActor (BluetoothAuthorization) -> Void)
}

/// IOBluetooth's connect and disconnect notifications. No polling anywhere:
/// one connect registration for every device, and one disconnect
/// registration per connected device, each delivered on the main run loop
/// and each dropped by `stop()`.
///
/// Nothing is registered until `start()`, so building one costs nothing and
/// touches no permission.
@MainActor
final class IOBluetoothSource: NSObject, BluetoothSource {
    var onConnect: ((BluetoothDeviceInfo) -> Void)?
    var onDisconnect: ((BluetoothDeviceInfo) -> Void)?

    private var connectNotification: IOBluetoothUserNotification?
    /// Keyed by address, so a device that reconnects is not watched twice and
    /// `stop()` can drop every one.
    private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]

    func connectedDevices() -> [BluetoothDeviceInfo] {
        Self.pairedConnected().map(Self.info)
    }

    func start() {
        guard connectNotification == nil else { return }
        connectNotification = IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(deviceConnected(_:device:))
        )
        // The connect notification reports devices already connected too,
        // and those are watched from there; these are watched now so a
        // device that leaves before that report arrives is still heard.
        for device in Self.pairedConnected() { watchDisconnect(of: device) }
    }

    func stop() {
        connectNotification?.unregister()
        connectNotification = nil
        for notification in disconnectNotifications.values { notification.unregister() }
        disconnectNotifications = [:]
    }

    private func watchDisconnect(of device: IOBluetoothDevice) {
        guard let address = device.addressString, disconnectNotifications[address] == nil else { return }
        disconnectNotifications[address] = device.register(
            forDisconnectNotification: self,
            selector: #selector(deviceDisconnected(_:device:))
        )
    }

    // `nonisolated` + `assumeIsolated` for the reason `ARCHITECTURE.md`
    // gives under Concurrency: IOBluetooth delivers on the run loop the
    // registration was made on, which is the main one, because `start()` is
    // main-actor isolated. The device is read into a `Sendable` value
    // before crossing, and looked up again by address on the main actor,
    // so no IOBluetooth object crosses the isolation boundary.
    @objc nonisolated private func deviceConnected(
        _ notification: IOBluetoothUserNotification, device: IOBluetoothDevice
    ) {
        let info = Self.info(device)
        MainActor.assumeIsolated {
            if let device = IOBluetoothDevice(addressString: info.address) {
                watchDisconnect(of: device)
            }
            onConnect?(info)
        }
    }

    @objc nonisolated private func deviceDisconnected(
        _ notification: IOBluetoothUserNotification, device: IOBluetoothDevice
    ) {
        // One disconnect per registration: the next connect registers anew.
        notification.unregister()
        let info = Self.info(device)
        MainActor.assumeIsolated {
            disconnectNotifications[info.address] = nil
            onDisconnect?(info)
        }
    }

    nonisolated private static func pairedConnected() -> [IOBluetoothDevice] {
        (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []).filter { $0.isConnected() }
    }

    nonisolated private static func info(_ device: IOBluetoothDevice) -> BluetoothDeviceInfo {
        BluetoothDeviceInfo(
            address: device.addressString ?? "",
            name: device.name ?? "",
            majorClass: UInt32(device.deviceClassMajor),
            minorClass: UInt32(device.deviceClassMinor),
            hasAudioService: UInt32(device.serviceClassMajor) & UInt32(kBluetoothServiceClassMajorAudio) != 0
        )
    }
}

/// The Bluetooth privacy setting, read through CoreBluetooth.
///
/// IOBluetooth has no authorization API of its own, but it sits behind the
/// same privacy service, and `CBManager.authorization` reads it without
/// prompting. Asking is creating a `CBCentralManager`: that is what shows
/// macOS's prompt (with `NSBluetoothAlwaysUsageDescription`), and its first
/// state update arrives once the prompt is answered. The manager is dropped
/// right after — it is a way to ask, not something this app scans with.
@MainActor
final class SystemBluetoothAccess: NSObject, BluetoothAccess, CBCentralManagerDelegate {
    private var manager: CBCentralManager?
    private var pending: [@MainActor (BluetoothAuthorization) -> Void] = []

    var status: BluetoothAuthorization {
        switch CBManager.authorization {
        case .allowedAlways:          return .allowed
        case .denied, .restricted:    return .denied
        case .notDetermined:          return .notDetermined
        @unknown default:             return .denied
        }
    }

    func request(_ completion: @escaping @MainActor (BluetoothAuthorization) -> Void) {
        pending.append(completion)
        guard manager == nil else { return }
        // `queue: nil` is the main queue, which is what makes the
        // `assumeIsolated` below sound.
        manager = CBCentralManager(delegate: self, queue: nil)
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        // `.unknown` and `.resetting` are not an answer yet; the next update
        // is. Read before crossing, so the manager itself never does.
        let state = central.state
        guard state != .unknown, state != .resetting else { return }
        MainActor.assumeIsolated {
            let answer = status
            let completions = pending
            pending = []
            manager?.delegate = nil
            manager = nil
            for completion in completions { completion(answer) }
        }
    }

    /// Privacy & Security › Bluetooth, where a denied grant is undone.
    static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth"
    )!
}

/// What a fresh `AppDelegate` uses until `configureForRealLaunch()`: no
/// radio, no registration, no prompt. The sandbox the other real-world
/// seams default to, for the same reason.
@MainActor
final class SandboxBluetoothSource: BluetoothSource {
    var onConnect: ((BluetoothDeviceInfo) -> Void)?
    var onDisconnect: ((BluetoothDeviceInfo) -> Void)?
    func connectedDevices() -> [BluetoothDeviceInfo] { [] }
    func start() {}
    func stop() {}
}

/// Never prompts: a request is answered "denied" at once, so a test that
/// switches the module on without injecting a fake sees the denied state
/// rather than a system dialog.
@MainActor
final class SandboxBluetoothAccess: BluetoothAccess {
    var status: BluetoothAuthorization { .notDetermined }
    func request(_ completion: @escaping @MainActor (BluetoothAuthorization) -> Void) {
        completion(.denied)
    }
}
