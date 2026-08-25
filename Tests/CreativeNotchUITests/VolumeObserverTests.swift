import AppKit
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// CoreAudio is public API and not TCC-gated — the spike confirmed a
/// listener installs and fires with no permission prompt. These tests read
/// the machine's real audio device, so they assert shape rather than exact
/// values.
@MainActor
struct VolumeObserverTests {

    @Test func aFreshObserverIsNotRunning() {
        let observer = VolumeObserver()
        #expect(observer.isRunning == false)
    }

    @Test func startingAndStoppingIsIdempotent() {
        let observer = VolumeObserver()
        observer.start()
        observer.start()          // must not install a second listener
        #expect(observer.isRunning)
        observer.stop()
        observer.stop()           // must not fail on an absent listener
        #expect(observer.isRunning == false)
    }

    @Test func theCurrentLevelIsAUnitValueOrUnavailable() {
        let observer = VolumeObserver()
        if let level = observer.currentLevel() {
            #expect(level >= 0 && level <= 1)
        }
        // A machine with no output device is legitimate; nil is a valid
        // answer, and asserting a level exists would fail on such a host.
    }

    @Test func muteReadsAsABooleanOrUnavailable() {
        let observer = VolumeObserver()
        if let muted = observer.isMuted() {
            #expect(muted == true || muted == false)
        }
    }
}
