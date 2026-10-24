import Foundation

/// What the Bluetooth alerts need to know about one device, as a plain value.
///
/// AppKit-free on purpose: `IOBluetoothDevice` is a class from a framework
/// Core must not import, and a test that needed one would need a paired
/// device and the Bluetooth permission. The UI's source reads these five
/// fields off the real device and hands this over; every decision below is
/// made from it.
public struct BluetoothDeviceInfo: Equatable, Sendable {
    /// Identity. Two people's "AirPods" are two devices.
    public var address: String
    public var name: String
    /// The class-of-device fields from the Bluetooth assigned numbers:
    /// major `0x04` is audio/video, and the minor class says which kind.
    public var majorClass: UInt32
    public var minorClass: UInt32
    /// Bit 21 of the class of device, "Audio" in the service-class field.
    public var hasAudioService: Bool

    public init(address: String, name: String, majorClass: UInt32, minorClass: UInt32, hasAudioService: Bool) {
        self.address = address
        self.name = name
        self.majorClass = majorClass
        self.minorClass = minorClass
        self.hasAudioService = hasAudioService
    }
}

/// The kinds of audio device worth a peek, each with its glyph.
///
/// The class of device can say "headphones" but not "AirPods Pro": Apple's
/// all report minor class headphones. The name is what tells them apart,
/// and it survives the owner's prefix ("Gerald's AirPods Pro"). A product
/// ID would be exact, but IOBluetooth exposes none publicly.
public enum BluetoothAudioKind: CaseIterable, Equatable, Sendable {
    case airPods, airPodsPro, airPodsMax, beats
    case headphones, headset, speaker, car
    /// Unclassified audio that says it carries audio.
    case audio

    // Minor classes under the audio/video major class
    // (`BluetoothAssignedNumbers.h`).
    private static let audioMajor: UInt32 = 0x04

    /// The kind, or `nil` for anything that is not an audio device.
    ///
    /// **The class decides whether it is audio; the name only refines.** A
    /// keyboard renamed "AirPods" is still a keyboard. And the audio service
    /// bit alone is not enough either: phones advertise it, and a phone
    /// connecting to tether is not headphones arriving.
    ///
    /// Video kit lives under the same major class — set-top boxes, VCRs,
    /// camcorders, monitors, TVs, conferencing, toys — and falls through to
    /// `nil`, because none of it is something you put on your ears.
    public static func classify(_ device: BluetoothDeviceInfo) -> BluetoothAudioKind? {
        guard device.majorClass == audioMajor else { return nil }
        let base: BluetoothAudioKind
        switch device.minorClass {
        case 0x06:             base = .headphones   // Headphones
        case 0x01, 0x02, 0x04: base = .headset      // Headset, hands-free, microphone
        case 0x05, 0x07, 0x0a: base = .speaker      // Loudspeaker, portable, HiFi
        case 0x08:             base = .car          // Car audio
        case 0x00:
            guard device.hasAudioService else { return nil }
            base = .audio
        default:
            return nil
        }
        return named(device.name) ?? base
    }

    /// Apple's product names, longest first so "AirPods Pro" is not read as
    /// "AirPods".
    private static func named(_ name: String) -> BluetoothAudioKind? {
        let lower = name.lowercased()
        if lower.contains("airpods max") { return .airPodsMax }
        if lower.contains("airpods pro") { return .airPodsPro }
        if lower.contains("airpods") { return .airPods }
        if lower.contains("beats") { return .beats }
        return nil
    }

    /// An SF Symbol per kind, each distinct so the glyph says what arrived.
    public var symbolName: String {
        switch self {
        case .airPods:    return "airpods"
        case .airPodsPro: return "airpodspro"
        case .airPodsMax: return "airpodsmax"
        case .beats:      return "beats.headphones"
        case .headphones: return "headphones"
        case .headset:    return "headset"
        case .speaker:    return "hifispeaker"
        case .car:        return "car"
        case .audio:      return "speaker.wave.2"
        }
    }

    /// What to call a device that has no name of its own. Apple's product
    /// names stay as they are in every language; the generic kinds are
    /// translated.
    public var noun: String {
        switch self {
        case .airPods:    return "AirPods"
        case .airPodsPro: return "AirPods Pro"
        case .airPodsMax: return "AirPods Max"
        case .beats:      return "Beats"
        case .headphones: return String(localized: "Headphones", bundle: .creativeNotch)
        case .headset:    return String(localized: "Headset", bundle: .creativeNotch)
        case .speaker:    return String(localized: "Speaker", bundle: .creativeNotch)
        case .car:        return String(localized: "Car audio", bundle: .creativeNotch)
        case .audio:      return String(localized: "Audio device", bundle: .creativeNotch)
        }
    }
}

/// An audio device arriving or leaving: what the peek shows.
///
/// No battery level, deliberately. IOBluetooth has no public battery API —
/// the properties that report AirPods' charge are private — and the
/// alternative is polling an IORegistry key, which this app does not do.
public struct BluetoothAudioEvent: Equatable, Sendable {
    public var name: String
    public var kind: BluetoothAudioKind
    public var connected: Bool

    public init(name: String, kind: BluetoothAudioKind, connected: Bool) {
        self.name = name
        self.kind = kind
        self.connected = connected
    }
}

/// Every string the Bluetooth peek shows or speaks, so the two cannot drift
/// apart — the pattern `PowerLabel` follows.
public enum BluetoothLabel {

    /// The device's own name, or its kind when it has none. Never an empty
    /// row, never a raw address.
    public static func title(for event: BluetoothAudioEvent) -> String {
        let trimmed = event.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? event.kind.noun : trimmed
    }

    public static func status(for event: BluetoothAudioEvent) -> String {
        event.connected
            ? String(localized: "Connected", bundle: .creativeNotch)
            : String(localized: "Disconnected", bundle: .creativeNotch)
    }

    /// What VoiceOver says, and the peek's accessibility label.
    public static func spoken(for event: BluetoothAudioEvent) -> String {
        let title = title(for: event)
        return event.connected
            ? String(localized: "\(title) connected", bundle: .creativeNotch, comment: "A Bluetooth device arrived: AirPods Pro connected")
            : String(localized: "\(title) disconnected", bundle: .creativeNotch, comment: "A Bluetooth device left: AirPods Pro disconnected")
    }
}

/// Which connect and disconnect callbacks are news.
///
/// IOBluetooth's connect notification reports every device that is already
/// connected at the moment it is registered, and headphones that bring up
/// two profiles can report twice. Neither is something arriving. So this
/// keeps the set of audio devices known to be connected, seeded with a
/// baseline when listening starts, and only a change to that set is an
/// event.
public struct BluetoothConnections: Equatable, Sendable {
    private var connected: Set<String> = []

    public init() {}

    /// What was connected when listening started. Not announced: switching
    /// the module on with AirPods already in is not them arriving.
    public mutating func baseline(_ devices: [BluetoothDeviceInfo]) {
        connected = Set(devices.filter { BluetoothAudioKind.classify($0) != nil }.map(\.address))
    }

    public mutating func connected(_ device: BluetoothDeviceInfo) -> BluetoothAudioEvent? {
        guard let kind = BluetoothAudioKind.classify(device),
              connected.insert(device.address).inserted else { return nil }
        return BluetoothAudioEvent(name: device.name, kind: kind, connected: true)
    }

    public mutating func disconnected(_ device: BluetoothDeviceInfo) -> BluetoothAudioEvent? {
        guard let kind = BluetoothAudioKind.classify(device),
              connected.remove(device.address) != nil else { return nil }
        return BluetoothAudioEvent(name: device.name, kind: kind, connected: false)
    }

    /// Forgets everything, so the next `baseline` decides afresh. A device
    /// that left while the module was off must not "disconnect" on return.
    public mutating func reset() {
        connected = []
    }
}

/// Whether this app may use Bluetooth, as macOS's privacy setting has it.
public enum BluetoothAuthorization: Equatable, Sendable {
    case notDetermined, allowed, denied
}

/// What the module should be doing, from the switch and the grant.
///
/// The one rule worth pinning: **off never asks.** The prompt appears only
/// when the person switches the alerts on and macOS has not been asked;
/// denied is a state the Settings row says out loud, because a module that
/// silently shows nothing is indistinguishable from a broken one.
public enum BluetoothRunState: Equatable, Sendable {
    case idle, request, listen, denied

    public static func decide(enabled: Bool, access: BluetoothAuthorization) -> BluetoothRunState {
        guard enabled else { return .idle }
        switch access {
        case .notDetermined: return .request
        case .allowed:       return .listen
        case .denied:        return .denied
        }
    }
}
