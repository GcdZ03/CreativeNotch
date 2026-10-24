import Foundation
import Testing
@testable import CreativeNotchCore

/// Which Bluetooth devices are audio, what they are called, and which
/// connect and disconnect callbacks are news.
///
/// Everything here is decided from a `BluetoothDeviceInfo` — a plain value a
/// test can build — so none of it needs IOBluetooth, a paired device, or the
/// Bluetooth permission.
struct BluetoothAudioTests {

    // Class-of-device numbers as the Bluetooth assigned numbers spell them.
    private static let audioMajor: UInt32 = 0x04
    private static let peripheralMajor: UInt32 = 0x05

    private static func device(
        _ name: String = "Headphones",
        address: String = "00-11-22-33-44-55",
        major: UInt32 = audioMajor,
        minor: UInt32 = 0x06,
        audioService: Bool = true
    ) -> BluetoothDeviceInfo {
        BluetoothDeviceInfo(
            address: address, name: name,
            majorClass: major, minorClass: minor, hasAudioService: audioService
        )
    }

    // MARK: - Classification

    /// A keyboard, a mouse or a phone connecting is not what this module is
    /// for. Delete the major-class check and a Magic Keyboard peeks.
    @Test func aPeripheralIsNotAudio() {
        let keyboard = Self.device("Magic Keyboard", major: Self.peripheralMajor, minor: 0x10, audioService: false)
        #expect(BluetoothAudioKind.classify(keyboard) == nil)
    }

    /// The service bit alone is not enough: phones advertise audio too, and
    /// a phone connecting to tether is not headphones arriving.
    @Test func anAudioServiceOnANonAudioDeviceIsNotAudio() {
        let phone = Self.device("iPhone", major: 0x02, minor: 0x03, audioService: true)
        #expect(BluetoothAudioKind.classify(phone) == nil)
    }

    /// Video kit lives under the audio/video major class too. A TV or a
    /// camcorder is not something you put on your ears.
    @Test func videoDevicesUnderTheAudioClassAreNotAudio() {
        for minor: UInt32 in [0x09, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10, 0x12] {
            #expect(BluetoothAudioKind.classify(Self.device("AV", minor: minor)) == nil, "minor \(minor)")
        }
    }

    @Test func minorClassesNameTheKind() {
        #expect(BluetoothAudioKind.classify(Self.device("X", minor: 0x06)) == .headphones)
        #expect(BluetoothAudioKind.classify(Self.device("X", minor: 0x01)) == .headset)
        #expect(BluetoothAudioKind.classify(Self.device("X", minor: 0x02)) == .headset)
        #expect(BluetoothAudioKind.classify(Self.device("X", minor: 0x05)) == .speaker)
        #expect(BluetoothAudioKind.classify(Self.device("X", minor: 0x07)) == .speaker)
        #expect(BluetoothAudioKind.classify(Self.device("X", minor: 0x0a)) == .speaker)
        #expect(BluetoothAudioKind.classify(Self.device("X", minor: 0x08)) == .car)
    }

    /// Unclassified audio counts only when it says it carries audio.
    @Test func unclassifiedAudioNeedsTheAudioServiceBit() {
        #expect(BluetoothAudioKind.classify(Self.device("X", minor: 0x00, audioService: true)) == .audio)
        #expect(BluetoothAudioKind.classify(Self.device("X", minor: 0x00, audioService: false)) == nil)
    }

    /// AirPods report themselves as headphones; the name is what tells the
    /// three apart, and it survives the owner's prefix ("Gerald's").
    @Test func airPodsAreRecognisedByNameWhateverTheOwnerPrefix() {
        #expect(BluetoothAudioKind.classify(Self.device("Gerald’s AirPods")) == .airPods)
        #expect(BluetoothAudioKind.classify(Self.device("Gerald’s AirPods Pro")) == .airPodsPro)
        #expect(BluetoothAudioKind.classify(Self.device("airpods max")) == .airPodsMax)
        #expect(BluetoothAudioKind.classify(Self.device("Beats Studio Pro")) == .beats)
    }

    /// A name is not a class. A keyboard someone renamed "AirPods" is still
    /// a keyboard, and the name never promotes a non-audio device.
    @Test func aNameNeverMakesANonAudioDeviceAudio() {
        let renamed = Self.device("AirPods", major: Self.peripheralMajor, minor: 0x10, audioService: false)
        #expect(BluetoothAudioKind.classify(renamed) == nil)
    }

    /// Every symbol named here exists in SF Symbols on macOS 26 — checked
    /// in the UI suite, where `NSImage` is available — and they differ, so
    /// the glyph says what kind of device it is.
    @Test func eachKindHasItsOwnSymbol() {
        let symbols = BluetoothAudioKind.allCases.map(\.symbolName)
        #expect(Set(symbols).count == symbols.count)
        #expect(BluetoothAudioKind.airPodsPro.symbolName == "airpodspro")
        #expect(BluetoothAudioKind.headphones.symbolName == "headphones")
        #expect(BluetoothAudioKind.speaker.symbolName == "hifispeaker")
    }

    // MARK: - Words

    @Test func thePeekNamesTheDeviceAndWhatHappened() {
        let event = BluetoothAudioEvent(name: "Gerald’s AirPods Pro", kind: .airPodsPro, connected: true)
        #expect(BluetoothLabel.title(for: event) == "Gerald’s AirPods Pro")
        #expect(BluetoothLabel.status(for: event) == "Connected")
        #expect(BluetoothLabel.spoken(for: event) == "Gerald’s AirPods Pro connected")

        let gone = BluetoothAudioEvent(name: "Sony WH-1000XM5", kind: .headphones, connected: false)
        #expect(BluetoothLabel.status(for: gone) == "Disconnected")
        #expect(BluetoothLabel.spoken(for: gone) == "Sony WH-1000XM5 disconnected")
    }

    /// A device with no name (or only whitespace) is named by its kind,
    /// never shown as an empty row or a raw address.
    @Test func anUnnamedDeviceIsNamedByItsKind() {
        let blank = BluetoothAudioEvent(name: "  ", kind: .speaker, connected: true)
        #expect(BluetoothLabel.title(for: blank) == "Speaker")
        #expect(BluetoothLabel.spoken(for: blank) == "Speaker connected")
    }

    // MARK: - Which callbacks are news

    /// IOBluetooth reports every device already connected when the connect
    /// notification is registered. Those are the baseline, not arrivals:
    /// switching the module on with AirPods in must not announce them.
    @Test func aDeviceInTheBaselineIsNotAnArrival() {
        var connections = BluetoothConnections()
        let pods = Self.device("AirPods", address: "A")
        connections.baseline([pods])

        #expect(connections.connected(pods) == nil)
    }

    @Test func aNewAudioDeviceIsAnArrival() {
        var connections = BluetoothConnections()
        connections.baseline([])

        #expect(connections.connected(Self.device("AirPods Pro", address: "A"))
                == BluetoothAudioEvent(name: "AirPods Pro", kind: .airPodsPro, connected: true))
    }

    /// Headphones that connect two profiles report twice. One peek.
    @Test func aRepeatedConnectIsNotNews() {
        var connections = BluetoothConnections()
        let phones = Self.device("WH-1000XM5", address: "A")
        #expect(connections.connected(phones) != nil)
        #expect(connections.connected(phones) == nil)
    }

    @Test func aDisconnectOfAKnownDeviceIsNewsOnce() {
        var connections = BluetoothConnections()
        let phones = Self.device("WH-1000XM5", address: "A")
        connections.baseline([phones])

        #expect(connections.disconnected(phones)
                == BluetoothAudioEvent(name: "WH-1000XM5", kind: .headphones, connected: false))
        #expect(connections.disconnected(phones) == nil)
    }

    /// And after leaving, coming back is news again.
    @Test func aDeviceThatLeftAndReturnsIsAnArrivalAgain() {
        var connections = BluetoothConnections()
        let phones = Self.device("WH-1000XM5", address: "A")
        connections.baseline([phones])
        _ = connections.disconnected(phones)

        #expect(connections.connected(phones) != nil)
    }

    /// Non-audio devices are never tracked, so they can never peek either way.
    @Test func nonAudioDevicesAreIgnoredBothWays() {
        var connections = BluetoothConnections()
        let mouse = Self.device("Mouse", address: "M", major: Self.peripheralMajor, minor: 0x20, audioService: false)
        #expect(connections.connected(mouse) == nil)
        #expect(connections.disconnected(mouse) == nil)
    }

    /// Identity is the address, not the name: two "AirPods" belonging to two
    /// people are two devices.
    @Test func identityIsTheAddress() {
        var connections = BluetoothConnections()
        connections.baseline([Self.device("AirPods", address: "A")])
        #expect(connections.connected(Self.device("AirPods", address: "B")) != nil)
    }

    /// A restart forgets what was connected, so the next baseline decides.
    @Test func resetForgetsEverything() {
        var connections = BluetoothConnections()
        let pods = Self.device("AirPods", address: "A")
        connections.baseline([pods])
        connections.reset()
        #expect(connections.disconnected(pods) == nil)
    }

    // MARK: - Permission

    /// Off does nothing — above all it never asks for Bluetooth.
    @Test func offNeverAsksAndNeverListens() {
        for access in [BluetoothAuthorization.notDetermined, .allowed, .denied] {
            #expect(BluetoothRunState.decide(enabled: false, access: access) == .idle)
        }
    }

    /// On, the prompt appears only when macOS has not been asked; once
    /// allowed it listens; denied, it says so instead of silently showing
    /// nothing.
    @Test func onAsksOnceThenListensOrReportsDenial() {
        #expect(BluetoothRunState.decide(enabled: true, access: .notDetermined) == .request)
        #expect(BluetoothRunState.decide(enabled: true, access: .allowed) == .listen)
        #expect(BluetoothRunState.decide(enabled: true, access: .denied) == .denied)
    }
}
