import AppKit
import Foundation
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// Bluetooth alerts joined to the app: switch to controller, controller to
/// arbiter, arbiter to the peek and to VoiceOver, and the grant to Settings.
///
/// The decisions — what is audio, what is news, where it ranks — are pinned
/// in Core. These pin the connections, on fake devices and a fake grant, so
/// nothing here registers with IOBluetooth or shows the Bluetooth prompt.
@MainActor
struct BluetoothWiringTests {

    private struct Rig {
        let delegate: AppDelegate
        let source: FakeBluetoothSource
        let access: FakeBluetoothAccess
        let spoken: Spoken
    }

    @MainActor final class Spoken { var lines: [String] = [] }

    private func make(_ grant: BluetoothAuthorization = .allowed) -> Rig {
        let source = FakeBluetoothSource()
        let access = FakeBluetoothAccess(grant)
        let spoken = Spoken()
        let delegate = AppDelegate()
        delegate.shelfTrash = TestTrash.shelf
        delegate.preferencesDefaults = TestDefaults.isolated("bluetooth")
        delegate.growthDelay = .zero
        delegate.shelfDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CreativeNotchBluetooth-\(UUID().uuidString)")
        delegate.playChime = { _ in }
        delegate.performHaptic = {}
        delegate.announce = { spoken.lines.append($0) }
        delegate.pointerLocation = { CGPoint(x: -10_000, y: -10_000) }
        delegate.screenDescriptors = { [] }
        delegate.bluetoothSource = source
        delegate.bluetoothAccess = access
        delegate.install(metrics: NotchedDelegate.metrics)
        delegate.clipboard?.poller.scheduleTimer = { _, _ in nil }
        delegate.clipboard?.poller.cancelTimer = { _ in }
        delegate.media?.supervisor.startHelper = {}
        delegate.media?.supervisor.stopHelper = {}
        return Rig(delegate: delegate, source: source, access: access, spoken: spoken)
    }

    private let pods = FakeBluetoothSource.pods("Gerald’s AirPods Pro")

    // MARK: - Lifecycle

    /// Building the wiring starts nothing and asks nothing.
    @Test func installBuildsTheControllerWithoutStartingIt() {
        let rig = make(.notDetermined)
        #expect(rig.delegate.bluetooth != nil)
        #expect(rig.source.startCount == 0)
        #expect(rig.access.requestCount == 0)
    }

    /// The launch path on a fresh install: the module ships off, so the
    /// launch never registers with IOBluetooth and never prompts.
    @Test func aFreshLaunchLeavesBluetoothAlone() {
        let rig = make(.notDetermined)
        rig.delegate.startSubsystems()

        #expect(rig.delegate.state.preferences.bluetooth == false)
        #expect(rig.source.startCount == 0)
        #expect(rig.access.requestCount == 0)
        rig.delegate.activity.stop()
    }

    /// Stored on, the launch starts it through the same leg a toggle runs.
    @Test func aLaunchWithItStoredOnStartsListening() {
        let rig = make(.allowed)
        rig.delegate.preferencesStore.setEnabled(true, for: .bluetooth)
        rig.delegate.startSubsystems()

        #expect(rig.source.isRunning)
        rig.delegate.activity.stop()
    }

    /// Switching it on from Settings is what asks — and only then.
    @Test func switchingItOnIsWhatAsks() {
        let rig = make(.notDetermined)
        rig.delegate.switchboard.setEnabled(true, for: .bluetooth, persist: true)

        #expect(rig.access.requestCount == 1)
        rig.access.answer(.allowed)
        #expect(rig.source.isRunning)
        #expect(rig.delegate.preferencesStore.load().bluetooth)
    }

    /// Off stops everything it runs, and withdraws a peek already showing.
    @Test func switchingItOffStopsListeningAndWithdrawsThePeek() {
        let rig = make()
        rig.delegate.switchboard.setEnabled(true, for: .bluetooth)
        rig.source.connect(pods)
        #expect(rig.delegate.state.state.presentation == .statusPeek)

        rig.delegate.switchboard.setEnabled(false, for: .bluetooth)

        #expect(!rig.source.isRunning)
        #expect(rig.delegate.state.state == .closed)
    }

    @Test func quittingStopsTheSource() {
        let rig = make()
        rig.delegate.switchboard.setEnabled(true, for: .bluetooth)
        rig.delegate.switchboard.stopAll()
        #expect(!rig.source.isRunning)
    }

    /// The activity gate reaches it: locked, an arrival does not peek.
    @Test func lockingSuppressesThePeek() {
        let rig = make()
        rig.delegate.switchboard.setEnabled(true, for: .bluetooth)
        rig.delegate.switchboard.setActivity(.locked)

        rig.source.connect(pods)

        #expect(rig.delegate.state.state == .closed)
        #expect(rig.source.isRunning, "the gate suspended the notifications")
    }

    // MARK: - The peek

    @Test func anArrivalBecomesAPeekAndIsSpoken() {
        let rig = make()
        rig.delegate.switchboard.setEnabled(true, for: .bluetooth)

        rig.source.connect(pods)

        let event = BluetoothAudioEvent(name: "Gerald’s AirPods Pro", kind: .airPodsPro, connected: true)
        #expect(rig.delegate.state.state == .peek(.bluetooth(event)))
        #expect(rig.spoken.lines == ["Gerald’s AirPods Pro connected"])
    }

    /// Recorded and then asked: a power peek already showing keeps the slot.
    @Test func aPowerPeekKeepsTheSlot() {
        let rig = make()
        rig.delegate.switchboard.setEnabled(true, for: .bluetooth)
        rig.delegate.showPowerPeek(.unplugged(level: 40))

        rig.source.connect(pods)

        #expect(rig.delegate.state.state == .peek(.power(.unplugged(level: 40))))
    }

    /// An open panel is a deliberate state; a device arriving does not
    /// replace it.
    @Test func anOpenPanelIsNotInterrupted() {
        let rig = make()
        rig.delegate.switchboard.setEnabled(true, for: .bluetooth)
        rig.delegate.state.transition(to: .open(.shelf))

        rig.source.connect(pods)

        #expect(rig.delegate.state.state == .open(.shelf))
    }

    /// It lapses on its own TTL, not power's or the timer's.
    @Test func itsReevaluationFollowsItsOwnTTL() {
        let event = BluetoothAudioEvent(name: "X", kind: .speaker, connected: true)
        let delay = AppDelegate.reevaluationDelay(
            for: .bluetooth(event), power: .seconds(3), timerDone: .seconds(600), bluetooth: .seconds(7)
        )
        #expect(delay == .seconds(7))
        #expect(AppDelegate.defaultBluetoothTTLDelay == .milliseconds(Int(PeekArbiter.bluetoothTTL * 1000)))
    }

    /// And the re-check really closes it once the arbiter has let it go.
    @Test func itClosesWhenItsTTLLapses() async {
        let rig = make()
        var clock: TimeInterval = 1000
        rig.delegate.now = { clock }
        rig.delegate.bluetoothTTLDelay = .zero
        rig.delegate.switchboard.setEnabled(true, for: .bluetooth)

        rig.source.connect(pods)
        #expect(rig.delegate.state.state.presentation == .statusPeek)

        clock += PeekArbiter.bluetoothTTL
        await rig.delegate.peekTTLTask?.value

        #expect(rig.delegate.state.state == .closed)
    }

    // MARK: - Settings

    /// Denied is said out loud, and only while the switch is on.
    @Test func aDenialReachesSettings() {
        let rig = make(.denied)
        let controller = PreferencesController(
            switchboard: rig.delegate.switchboard, state: rig.delegate.state,
            launchAtLogin: rig.delegate.launchAtLogin, presenter: { _ in }
        )
        #expect(controller.isBluetoothDenied == false)

        controller.setEnabled(true, for: .bluetooth)

        #expect(rig.delegate.state.bluetoothAccess == .denied)
        #expect(controller.isBluetoothDenied)
        #expect(rig.access.requestCount == 0)

        controller.setEnabled(false, for: .bluetooth)
        #expect(controller.isBluetoothDenied == false)
    }

    /// Allowed in System Settings, then Settings reopened: it starts, with
    /// no relaunch and no toggle.
    @Test func showingSettingsRereadsTheGrant() {
        let rig = make(.denied)
        let controller = PreferencesController(
            switchboard: rig.delegate.switchboard, state: rig.delegate.state,
            launchAtLogin: rig.delegate.launchAtLogin, presenter: { _ in }
        )
        controller.setEnabled(true, for: .bluetooth)
        rig.access.status = .allowed

        controller.show()

        #expect(rig.source.isRunning)
        #expect(controller.isBluetoothDenied == false)
    }

    @Test func theDeniedRowOpensBluetoothSettingsThroughTheSeam() {
        let rig = make(.denied)
        var opened = 0
        rig.delegate.openBluetoothSettings = { opened += 1 }
        let controller = PreferencesController(
            switchboard: rig.delegate.switchboard, state: rig.delegate.state,
            launchAtLogin: rig.delegate.launchAtLogin, presenter: { _ in }
        )

        controller.openBluetoothSettings()

        #expect(opened == 1)
    }

    /// Every glyph the module names exists on this macOS — a missing SF
    /// Symbol draws nothing at all, silently.
    @Test func everySymbolExists() {
        for kind in BluetoothAudioKind.allCases {
            #expect(NSImage(systemSymbolName: kind.symbolName, accessibilityDescription: nil) != nil, "\(kind)")
        }
        let row = PreferencesView.rows.first { $0.module == .bluetooth }
        #expect(row.map { NSImage(systemSymbolName: $0.symbolName, accessibilityDescription: nil) != nil } == true)
    }

    /// The usage string is what macOS shows in the prompt, and without it
    /// IOBluetooth and CoreBluetooth terminate the app on first use.
    @Test func theInfoPlistExplainsBluetooth() throws {
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Info.plist")
        let data = try Data(contentsOf: plist)
        let dict = try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let text = try #require(dict["NSBluetoothAlwaysUsageDescription"] as? String)
        #expect(text.isEmpty == false)
    }
}
