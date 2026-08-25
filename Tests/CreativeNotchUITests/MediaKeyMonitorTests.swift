import AppKit
import Testing
@testable import CreativeNotchUI

/// The only always-installed global monitor in the project, admitted
/// against the letter of the no-polling rule because the rule exists to
/// stop monitors that fire continuously and this one fires a few dozen
/// times a day. See spec section 3.2.
///
/// The decoding is pure and tested directly; the monitor's lifecycle is
/// tested through an injected installer, since a real global monitor needs
/// Accessibility and a keyboard.
@MainActor
struct MediaKeyMonitorTests {

    // NX_KEYTYPE values, shifted into place as data1 carries them.
    private func data1(keyCode: Int) -> Int { (keyCode << 16) }

    @Test func volumeAndBrightnessKeysAreRecognised() {
        for code in [0, 1, 2, 3, 7] {   // SOUND_UP, SOUND_DOWN, BRIGHT_UP, BRIGHT_DOWN, MUTE
            #expect(MediaKeyMonitor.isMediaKey(subtype: 8, data1: data1(keyCode: code)))
        }
    }

    @Test func otherSystemKeysAreIgnored() {
        // Keyboard illumination and eject are system-defined too, and must
        // not be mistaken for a level change.
        for code in [4, 6, 21, 22] {
            #expect(MediaKeyMonitor.isMediaKey(subtype: 8, data1: data1(keyCode: code)) == false)
        }
    }

    @Test func onlySubtypeEightCounts() {
        #expect(MediaKeyMonitor.isMediaKey(subtype: 7, data1: data1(keyCode: 0)) == false)
        #expect(MediaKeyMonitor.isMediaKey(subtype: 0, data1: data1(keyCode: 0)) == false)
    }

    @Test func startingInstallsExactlyOneMonitor() {
        let monitor = MediaKeyMonitor()
        var installs = 0
        monitor.installMonitor = { _ in installs += 1; return installs as NSNumber }
        monitor.removeMonitor = { _ in }

        monitor.start()
        monitor.start()

        #expect(installs == 1)
        #expect(monitor.isRunning)
    }

    @Test func stoppingRemovesIt() {
        let monitor = MediaKeyMonitor()
        var removals = 0
        monitor.installMonitor = { _ in 1 as NSNumber }
        monitor.removeMonitor = { _ in removals += 1 }

        monitor.start()
        monitor.stop()
        monitor.stop()

        #expect(removals == 1)
        #expect(monitor.isRunning == false)
    }
}
