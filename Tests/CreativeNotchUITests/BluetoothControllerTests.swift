import Foundation
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// A source a test drives by hand: no radio, no IOBluetooth, no permission.
@MainActor
final class FakeBluetoothSource: BluetoothSource {
    var onConnect: ((BluetoothDeviceInfo) -> Void)?
    var onDisconnect: ((BluetoothDeviceInfo) -> Void)?
    var connected: [BluetoothDeviceInfo] = []
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var isRunning = false

    func connectedDevices() -> [BluetoothDeviceInfo] { connected }
    func start() { startCount += 1; isRunning = true }
    func stop() { stopCount += 1; isRunning = false }

    func connect(_ device: BluetoothDeviceInfo) { onConnect?(device) }
    func disconnect(_ device: BluetoothDeviceInfo) { onDisconnect?(device) }

    static func pods(_ name: String = "AirPods Pro", address: String = "A") -> BluetoothDeviceInfo {
        BluetoothDeviceInfo(address: address, name: name, majorClass: 0x04, minorClass: 0x06, hasAudioService: true)
    }

    static let keyboard = BluetoothDeviceInfo(
        address: "K", name: "Magic Keyboard", majorClass: 0x05, minorClass: 0x10, hasAudioService: false
    )
}

/// An access a test answers by hand: it records requests instead of showing
/// macOS's prompt, and replies only when told to.
@MainActor
final class FakeBluetoothAccess: BluetoothAccess {
    var status: BluetoothAuthorization
    private(set) var requestCount = 0
    private var pending: [@MainActor (BluetoothAuthorization) -> Void] = []

    init(_ status: BluetoothAuthorization) { self.status = status }

    func request(_ completion: @escaping @MainActor (BluetoothAuthorization) -> Void) {
        requestCount += 1
        pending.append(completion)
    }

    /// The person answers the prompt.
    func answer(_ answer: BluetoothAuthorization) {
        status = answer
        let completions = pending
        pending = []
        for completion in completions { completion(answer) }
    }
}

@MainActor
struct BluetoothControllerTests {

    private func make(
        _ access: BluetoothAuthorization = .allowed
    ) -> (BluetoothController, FakeBluetoothSource, FakeBluetoothAccess, Box) {
        let source = FakeBluetoothSource()
        let fakeAccess = FakeBluetoothAccess(access)
        let controller = BluetoothController(source: source, access: fakeAccess)
        let box = Box()
        controller.onEvent = { box.events.append($0) }
        controller.onAccessChange = { box.access.append($0) }
        return (controller, source, fakeAccess, box)
    }

    @MainActor final class Box {
        var events: [BluetoothAudioEvent] = []
        var access: [BluetoothAuthorization] = []
    }

    // MARK: - Lifecycle and permission

    /// Built is not started: constructing the controller registers nothing
    /// and asks for nothing.
    @Test func buildingItTouchesNothing() {
        let (_, source, access, _) = make(.notDetermined)
        #expect(source.startCount == 0)
        #expect(access.requestCount == 0)
    }

    @Test func enablingWithAccessListens() {
        let (controller, source, access, _) = make(.allowed)
        controller.setEnabled(true)
        #expect(source.isRunning)
        #expect(controller.isListening)
        #expect(access.requestCount == 0)
    }

    /// Switching off stops everything it runs — the module rule.
    @Test func disablingStopsTheSource() {
        let (controller, source, _, _) = make(.allowed)
        controller.setEnabled(true)
        controller.setEnabled(false)
        #expect(!source.isRunning)
        #expect(!controller.isListening)
    }

    /// The prompt appears only on enabling, and listening starts only once
    /// it is granted.
    @Test func enablingUndecidedAsksAndListensOnlyOnceGranted() {
        let (controller, source, access, box) = make(.notDetermined)
        controller.setEnabled(true)
        #expect(access.requestCount == 1)
        #expect(!source.isRunning)

        access.answer(.allowed)

        #expect(source.isRunning)
        #expect(box.access.last == .allowed)
    }

    @Test func aDeniedPromptPublishesDenialAndNeverListens() {
        let (controller, source, access, box) = make(.notDetermined)
        controller.setEnabled(true)
        access.answer(.denied)

        #expect(!source.isRunning)
        #expect(box.access.last == .denied)
    }

    /// Already denied: no prompt (macOS would not show one anyway), the
    /// state is published so Settings can say so.
    @Test func alreadyDeniedDoesNotAskAndSaysSo() {
        let (controller, source, access, box) = make(.denied)
        controller.setEnabled(true)
        #expect(access.requestCount == 0)
        #expect(!source.isRunning)
        #expect(box.access.last == .denied)
    }

    /// Switched off while the prompt is up, then granted: still off.
    @Test func aGrantArrivingAfterSwitchingOffDoesNotStartIt() {
        let (controller, source, access, _) = make(.notDetermined)
        controller.setEnabled(true)
        controller.setEnabled(false)
        access.answer(.allowed)
        #expect(!source.isRunning)
    }

    /// Toggling while a prompt is up does not stack a second request.
    @Test func onlyOneRequestIsInFlight() {
        let (controller, _, access, _) = make(.notDetermined)
        controller.setEnabled(true)
        controller.setEnabled(false)
        controller.setEnabled(true)
        #expect(access.requestCount == 1)
    }

    /// A prompt that comes back still undecided is not asked again in a
    /// loop: the next ask waits for the next deliberate moment.
    @Test func anUndecidedAnswerIsNotReaskedInALoop() {
        let (controller, source, access, _) = make(.notDetermined)
        controller.setEnabled(true)
        access.answer(.notDetermined)
        #expect(access.requestCount == 1)
        #expect(!source.isRunning)
    }

    /// Granted in System Settings after a denial: reopening Settings
    /// re-reads it and starts listening, no relaunch.
    @Test func refreshingAfterAGrantInSystemSettingsStartsListening() {
        let (controller, source, access, box) = make(.denied)
        controller.setEnabled(true)
        access.status = .allowed

        controller.refreshAccess()

        #expect(source.isRunning)
        #expect(box.access.last == .allowed)
    }

    /// Refreshing while off reads the status but never prompts.
    @Test func refreshingWhileOffNeverAsks() {
        let (controller, _, access, _) = make(.notDetermined)
        controller.refreshAccess()
        #expect(access.requestCount == 0)
    }

    @Test func stopStopsTheSource() {
        let (controller, source, _, _) = make(.allowed)
        controller.setEnabled(true)
        controller.stop()
        #expect(!source.isRunning)
    }

    // MARK: - Events

    @Test func anArrivingAudioDeviceIsAnEvent() {
        let (controller, source, _, box) = make()
        controller.setEnabled(true)
        source.connect(FakeBluetoothSource.pods())
        #expect(box.events == [BluetoothAudioEvent(name: "AirPods Pro", kind: .airPodsPro, connected: true)])
    }

    @Test func aKeyboardIsNotAnEvent() {
        let (controller, source, _, box) = make()
        controller.setEnabled(true)
        source.connect(FakeBluetoothSource.keyboard)
        #expect(box.events.isEmpty)
    }

    /// What was connected when listening started is the baseline: the
    /// source's report of it is not news, its leaving is.
    @Test func theBaselineIsNotAnnouncedButItsLeavingIs() {
        let (controller, source, _, box) = make()
        source.connected = [FakeBluetoothSource.pods()]
        controller.setEnabled(true)

        source.connect(FakeBluetoothSource.pods())
        #expect(box.events.isEmpty)

        source.disconnect(FakeBluetoothSource.pods())
        #expect(box.events.map(\.connected) == [false])
    }

    /// Locked or asleep: tracked, not shown — and not shown later either.
    @Test func whileInactiveNothingPeeksButTrackingContinues() {
        let (controller, source, _, box) = make()
        controller.setEnabled(true)
        controller.setActivity(.locked)
        source.connect(FakeBluetoothSource.pods())
        #expect(box.events.isEmpty)

        controller.setActivity(.active)
        source.connect(FakeBluetoothSource.pods())
        #expect(box.events.isEmpty, "the arrival behind the lock screen was replayed")

        source.disconnect(FakeBluetoothSource.pods())
        #expect(box.events.count == 1)
    }

    /// A callback that lands after switching off is dropped.
    @Test func aLateCallbackAfterStoppingIsIgnored() {
        let (controller, source, _, box) = make()
        controller.setEnabled(true)
        controller.setEnabled(false)
        source.connect(FakeBluetoothSource.pods())
        #expect(box.events.isEmpty)
    }

    /// A device that left while the module was off must not "connect" as
    /// news on return just because the old set was kept — nor disconnect.
    @Test func restartingTakesAFreshBaseline() {
        let (controller, source, _, box) = make()
        source.connected = [FakeBluetoothSource.pods()]
        controller.setEnabled(true)
        controller.setEnabled(false)
        source.connected = []
        controller.setEnabled(true)

        source.disconnect(FakeBluetoothSource.pods())
        #expect(box.events.isEmpty)
    }
}
