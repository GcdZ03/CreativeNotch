import Foundation
import Testing
@testable import CreativeNotchCore

/// Where a Bluetooth peek ranks, how long it lasts, and what is said.
///
/// drag > finished timer > power > Bluetooth > now-playing. A device
/// arriving confirms something the person just did with their own hands,
/// so it yields to everything that is news to them, and outranks only the
/// ambient music peek.
struct BluetoothPeekArbitrationTests {
    private let t0: TimeInterval = 1000
    private let pods = BluetoothAudioEvent(name: "AirPods Pro", kind: .airPodsPro, connected: true)
    private let track = TrackSnapshot(title: "T", artist: "A", isPlaying: true)

    @Test func aBluetoothEventPeeks() {
        var a = PeekArbiter()
        a.recordBluetooth(pods, now: t0)
        #expect(a.content(now: t0) == .bluetooth(pods))
    }

    @Test func itOutranksNowPlaying() {
        var a = PeekArbiter()
        a.setNowPlaying(track)
        a.recordBluetooth(pods, now: t0)
        #expect(a.content(now: t0) == .bluetooth(pods))
    }

    /// The charger slipping out is news; headphones you just put on are not.
    @Test func powerOutranksIt() {
        var a = PeekArbiter()
        a.recordBluetooth(pods, now: t0)
        a.recordPower(.unplugged(level: 50), now: t0)
        #expect(a.content(now: t0) == .power(.unplugged(level: 50)))
    }

    @Test func aFinishedTimerAndADragOutrankIt() {
        var a = PeekArbiter()
        a.recordBluetooth(pods, now: t0)
        a.recordTimerFinished(TimerCompletion(duration: 60, lateness: 0), now: t0)
        #expect(a.content(now: t0) == .timerDone(TimerCompletion(duration: 60, lateness: 0)))
        a.setDragActive(true)
        #expect(a.content(now: t0) == .dragTarget)
    }

    /// Revealed when the power peek above it lapses, if still live.
    @Test func itIsRevealedWhenPowerLapses() {
        var a = PeekArbiter()
        a.recordPower(.unplugged(level: 50), now: t0)
        a.recordBluetooth(pods, now: t0 + 2)
        #expect(a.content(now: t0 + PeekArbiter.powerTTL) == .bluetooth(pods))
    }

    @Test func itExpiresAtItsTTLAndFallsBackToMusic() {
        var a = PeekArbiter()
        a.setNowPlaying(track)
        a.recordBluetooth(pods, now: t0)
        #expect(a.content(now: t0 + PeekArbiter.bluetoothTTL - 0.01) == .bluetooth(pods))
        #expect(a.content(now: t0 + PeekArbiter.bluetoothTTL) == .nowPlaying(track))
    }

    /// Shorter than power's: a name and one word, confirming what the
    /// person just did — it should be out of the way quickly.
    @Test func itsTTLIsShorterThanPowers() {
        #expect(PeekArbiter.bluetoothTTL < PeekArbiter.powerTTL)
        #expect(PeekArbiter.bluetoothTTL >= 2)
    }

    /// A second device replaces the first rather than queueing behind it.
    @Test func aNewerEventReplacesTheOlder() {
        var a = PeekArbiter()
        a.recordBluetooth(pods, now: t0)
        let gone = BluetoothAudioEvent(name: "Speaker", kind: .speaker, connected: false)
        a.recordBluetooth(gone, now: t0 + 1)
        #expect(a.content(now: t0 + 1) == .bluetooth(gone))
    }

    /// Switching the module off withdraws its peek and only its peek.
    @Test func clearingBluetoothWithdrawsOnlyItsPeek() {
        var a = PeekArbiter()
        a.setNowPlaying(track)
        a.recordBluetooth(pods, now: t0)
        a.clearBluetooth()
        #expect(a.content(now: t0) == .nowPlaying(track))
    }

    /// One row hanging below the notch, the battery peek's shape.
    @Test func itUsesTheStatusPeekShape() {
        #expect(NotchState.peek(.bluetooth(pods)).presentation == .statusPeek)
    }

    // MARK: - VoiceOver

    @Test func itIsSpokenInTheLabelsWords() {
        #expect(PeekAnnouncement.text(for: .bluetooth(pods)) == "AirPods Pro connected")
    }

    /// Unsolicited, so spoken when it appears — and not again when a
    /// re-check finds the same event still showing.
    @Test func itIsAnnouncedOnceWhenItAppears() {
        #expect(PeekAnnouncement.announcement(showing: .bluetooth(pods), replacing: nil) == "AirPods Pro connected")
        #expect(PeekAnnouncement.announcement(showing: .bluetooth(pods), replacing: .bluetooth(pods)) == nil)
    }
}
