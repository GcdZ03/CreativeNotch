import AppKit
import Carbon.HIToolbox
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// The recorder's lifecycle.
///
/// What is asserted is the **monitor's lifetime**, not the keystroke capture:
/// synthesising a `keyDown` that a local monitor would see needs a real event
/// queue and a focused window. The capture path itself is a two-line mapping
/// over `HotKeyModifier.carbon(fromCocoaRawValue:)`, which is tested directly
/// in Core.
@MainActor
struct HotKeyRecorderTests {

    /// A recorder whose monitor is counted rather than really installed.
    /// `isRecording` is a flag the type sets itself; the counts are evidence.
    private func makeCounted() -> (HotKeyRecorder, () -> Int, () -> Int) {
        final class Counts { var installs = 0; var removes = 0 }
        let counts = Counts()
        let recorder = HotKeyRecorder { _ in }
        recorder.installMonitor = { _ in
            counts.installs += 1
            return counts.installs as NSNumber
        }
        recorder.removeMonitor = { _ in counts.removes += 1 }
        return (recorder, { counts.installs }, { counts.removes })
    }

    @Test func aFreshRecorderIsNotRecording() {
        let recorder = HotKeyRecorder { _ in }
        #expect(recorder.isRecording == false)
        #expect(recorder.isMonitoring == false)
    }

    @Test func startingBeginsRecordingAndStoppingEndsIt() {
        let (recorder, installs, removes) = makeCounted()

        recorder.start()
        #expect(recorder.isRecording)
        #expect(recorder.isMonitoring)
        #expect(installs() == 1)

        recorder.stop()
        #expect(recorder.isRecording == false)
        #expect(recorder.isMonitoring == false)
        #expect(removes() == 1)
    }

    /// **Starting twice must install one monitor.** Without the guard the
    /// second install overwrites the first's token, and the first monitor is
    /// then unreachable -- installed for the life of the process, which is
    /// exactly the cost this project refuses. `isRecording` reads identically
    /// either way, which is why the count exists.
    @Test func startingTwiceInstallsOneMonitor() {
        let (recorder, installs, removes) = makeCounted()

        recorder.start()
        recorder.start()

        #expect(installs() == 1, "a second monitor was installed and orphaned")
        recorder.stop()
        #expect(removes() == 1)
    }

    /// And stopping twice must remove once. `NSEvent.removeMonitor` on a token
    /// already removed is not safe, so the second call has to do nothing.
    @Test func stoppingTwiceRemovesOnce() {
        let (recorder, _, removes) = makeCounted()
        recorder.start()

        recorder.stop()
        recorder.stop()

        #expect(removes() == 1, "a stale monitor token was removed twice")
        #expect(recorder.isMonitoring == false)
    }

    /// The monitor is installed only while recording -- a local monitor, not a
    /// global one, and gone the moment recording ends. That distinction is
    /// what the whole module rests on.
    @Test func noMonitorSurvivesRecordingEnding() {
        let (recorder, installs, removes) = makeCounted()

        recorder.start(); recorder.stop()
        recorder.start(); recorder.stop()

        #expect(installs() == 2)
        #expect(removes() == 2)
        #expect(recorder.isMonitoring == false)
    }

    /// The recorder is held by the preferences controller rather than rebuilt
    /// by the view: a SwiftUI body runs many times, and a recorder rebuilt
    /// mid-recording would drop its monitor and leave the button stuck on
    /// "Press a key…".
    @Test func thePreferencesControllerReusesOneRecorderPerHotkey() {
        let store = HotKeyStore(defaults: TestDefaults.isolated("recorder"))
        let hotKey = HotKeyController(store: store)
        let delegate = AppDelegate()
        delegate.preferencesDefaults = TestDefaults.isolated("recorder-prefs")
        let controller = PreferencesController(
            switchboard: delegate.switchboard,
            state: delegate.state,
            launchAtLogin: delegate.launchAtLogin
        )

        let first = controller.recorder(for: hotKey)
        let second = controller.recorder(for: hotKey)

        #expect(first === second)
    }
}
