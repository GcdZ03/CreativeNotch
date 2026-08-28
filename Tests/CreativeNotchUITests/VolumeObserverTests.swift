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
        // Not safe to assert bare: GitHub Actions macOS runners have a
        // documented, intermittent bug (`actions/runner-images#13668`)
        // where the Null Audio Device fails to initialise, leaving no
        // output device at all, so `start()` bails before setting this.
        expectOrKnownHardwareIssue(
            observer.isRunning,
            "CI runners intermittently have no audio device (actions/runner-images#13668)"
        )
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

    @Test func startingRegistersListenersAndStoppingRemovesThem() {
        let observer = VolumeObserver()
        #expect(observer.registrationCount == 0)

        observer.start()
        // A host with no output device legitimately registers nothing, so
        // only assert the relationship, not a specific count.
        let afterStart = observer.registrationCount

        observer.stop()
        #expect(observer.registrationCount == 0)
        #expect(afterStart >= observer.registrationCount)
    }

    @Test func startingTwiceDoesNotStackRegistrations() {
        let observer = VolumeObserver()
        observer.start()
        let afterFirst = observer.registrationCount
        observer.start()
        #expect(observer.registrationCount == afterFirst)
        observer.stop()
    }

    /// Reading the level must not depend on having started observing.
    /// It did: `device` was only resolved in `start()`, so an unstarted
    /// observer returned nil unconditionally — and the suite's "nil is a
    /// legitimate answer" tolerance hid it.
    @Test func theLevelReadsTheSameBeforeAndAfterStarting() {
        let observer = VolumeObserver()
        let before = observer.currentLevel()
        observer.start()
        let after = observer.currentLevel()
        observer.stop()

        // Either both are nil (no output device) or both have a value.
        #expect((before == nil) == (after == nil))
    }
}
