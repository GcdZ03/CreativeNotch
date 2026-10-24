import Foundation
import CreativeNotchCore

/// Bluetooth alerts' one stateful object: the switch, the grant, the source
/// and which connections are news.
///
/// Shaped after `PowerController` — built in `AppDelegate.install`, started
/// and stopped by `ModuleSwitchboard`, gated by `setActivity` — with one
/// addition the power module never needed: a permission. `BluetoothRunState`
/// (Core) decides from the switch and the grant whether to listen, ask, or
/// report a denial; this carries the decision out.
///
/// **Event-driven end to end.** IOBluetooth delivers connect and disconnect
/// notifications; nothing here wakes on a clock, and switched off nothing is
/// registered at all.
@MainActor
final class BluetoothController {

    /// An audio device arrived or left, while somebody can see the screen.
    var onEvent: ((BluetoothAudioEvent) -> Void)?

    /// The grant as last read, for the Settings row's denied state.
    var onAccessChange: ((BluetoothAuthorization) -> Void)?

    private let source: BluetoothSource
    private let access: BluetoothAccess
    private var connections = BluetoothConnections()
    private var enabled = false
    private var activity: SystemActivity = .active
    private var isRequesting = false

    /// Whether the source is registered. Internal, for the lifecycle proof.
    private(set) var isListening = false

    init(source: BluetoothSource, access: BluetoothAccess) {
        self.source = source
        self.access = access
        // `[weak self]`: the source holds these closures, and a strong
        // capture would be a component keeping its owner alive — the
        // reason `PowerController`'s observer closure is weak.
        source.onConnect = { [weak self] device in self?.deviceConnected(device) }
        source.onDisconnect = { [weak self] device in self?.deviceDisconnected(device) }
    }

    /// The switch. On asks for Bluetooth only if macOS has never been asked;
    /// off unregisters everything.
    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        reevaluate()
    }

    /// Re-reads the grant — called when Settings is shown, the one moment
    /// someone who just allowed Bluetooth in System Settings comes back to
    /// look. No observer: macOS posts no notification for a privacy change.
    func refreshAccess() {
        reevaluate()
    }

    /// Quitting. Unregisters whatever the switch says.
    func stop() {
        stopListening()
    }

    /// The lock and sleep gate. Like power's, it suppresses peeks and leaves
    /// the notifications registered: a registration that never fires costs
    /// nothing, and suspending it would mean the connection set is wrong on
    /// unlock — AirPods taken out behind the lock screen would later
    /// "disconnect" from nothing, or arrive twice.
    func setActivity(_ next: SystemActivity) {
        activity = next
    }

    /// `answered` is a request's result. Used instead of re-reading the
    /// status, so an answer that comes back still undecided is not asked
    /// again in a loop — the next ask waits for the next toggle or the next
    /// time Settings is shown.
    private func reevaluate(answered: BluetoothAuthorization? = nil) {
        let status = answered ?? access.status
        onAccessChange?(status)

        switch BluetoothRunState.decide(enabled: enabled, access: status) {
        case .idle, .denied:
            stopListening()
        case .listen:
            startListening()
        case .request:
            stopListening()
            guard answered == nil, !isRequesting else { return }
            isRequesting = true
            access.request { [weak self] answer in
                guard let self else { return }
                self.isRequesting = false
                // The switch is read again here, not captured: off while the
                // prompt was up means off, whatever the answer.
                self.reevaluate(answered: answer)
            }
        }
    }

    private func startListening() {
        guard !isListening else { return }
        // Baseline before registering, so the source's report of what is
        // already connected finds those devices known.
        connections.baseline(source.connectedDevices())
        source.start()
        isListening = true
    }

    private func stopListening() {
        guard isListening else { return }
        source.stop()
        connections.reset()
        isListening = false
    }

    /// Tracking advances whatever the activity, the way power's arming
    /// does, so an arrival behind the lock screen is spent rather than
    /// replayed on unlock. Only the peek is gated.
    private func deviceConnected(_ device: BluetoothDeviceInfo) {
        guard isListening, let event = connections.connected(device) else { return }
        if activity == .active { onEvent?(event) }
    }

    private func deviceDisconnected(_ device: BluetoothDeviceInfo) {
        guard isListening, let event = connections.disconnected(device) else { return }
        if activity == .active { onEvent?(event) }
    }
}
