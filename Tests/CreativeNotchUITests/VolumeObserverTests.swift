import AppKit
import CoreAudio
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

        // A host with no output device legitimately registers nothing, so
        // the precondition is asserted softly and everything that only
        // means something when it held is asserted hard, below. The
        // earlier shape — `afterStart >= registrationCount` — was
        // trivially true whenever the final count was 0, which is to say
        // always: it passed with `start()` gutted entirely.
        let hasDevice = observer.deviceProvider() != 0

        observer.start()
        let afterStart = observer.registrationCount

        observer.stop()
        #expect(observer.registrationCount == 0)

        expectOrKnownHardwareIssue(hasDevice, "no default output device on this host")
        if hasDevice { #expect(afterStart > 0) }
    }

    @Test func startingTwiceDoesNotStackRegistrations() {
        let observer = VolumeObserver()
        let hasDevice = observer.deviceProvider() != 0

        observer.start()
        let afterFirst = observer.registrationCount
        observer.start()
        #expect(observer.registrationCount == afterFirst)
        observer.stop()

        // Without this, the equality above holds vacuously at 0 == 0.
        expectOrKnownHardwareIssue(hasDevice, "no default output device on this host")
        if hasDevice { #expect(afterFirst > 0) }
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

    /// The bug: `start()` resolved `device`, then bailed via `guard device
    /// != 0` *before* ever registering the system-object listener that
    /// watches for the default output device changing. A transient window
    /// with no default device — Bluetooth headphones dropping, waking from
    /// sleep, switching outputs — left `isRunning == false` and nothing
    /// listening, so nothing would ever notice the device coming back: the
    /// spec's own words are "a missed re-subscription means the volume half
    /// silently stops." `deviceProvider` forces that exact window
    /// deterministically, without needing to unplug real hardware.
    @Test func aDeviceLessStartStillRegistersTheSystemListener() {
        let observer = VolumeObserver()
        observer.deviceProvider = { AudioDeviceID(0) }
        observer.start()

        #expect(observer.isWatchingForDefaultDeviceChanges)
        #expect(observer.isRunning == false)   // no device: nothing else could start
    }

    /// The regression this fixes: `start()` moved the system-listener
    /// registration ahead of the `guard device != 0` check, but `stop()`
    /// still opened with `guard isRunning else { return }` -- a guard whose
    /// invariant that move broke. A device-less `start()` leaves
    /// `isRunning == false` while the system listener is installed, so the
    /// old `stop()` no-oped and leaked it.
    @Test func stopTearsDownTheSystemListenerEvenAfterADeviceLessStart() {
        let observer = VolumeObserver()
        observer.deviceProvider = { AudioDeviceID(0) }
        observer.start()
        #expect(observer.isWatchingForDefaultDeviceChanges)   // sanity: precondition holds

        observer.stop()

        #expect(observer.isWatchingForDefaultDeviceChanges == false)
    }

    /// Worse than a leak: because the old `stop()` left the system listener
    /// installed, a later default-device change would fire it and call
    /// `self.stop(); self.start()` -- and if a device now existed, `start()`
    /// would flip `isRunning` back to `true`, resurrecting an observer the
    /// caller believed was stopped. `simulateDefaultDeviceChange()` fires
    /// the exact block CoreAudio would, without needing a real device
    /// change on demand.
    @Test func stopPreventsADeviceChangeFromResurrectingTheObserver() {
        let observer = VolumeObserver()
        var device = AudioDeviceID(0)
        observer.deviceProvider = { device }
        observer.start()             // device-less: isRunning stays false
        observer.stop()               // must tear down the system listener

        device = AudioDeviceID(9999)  // pretend a default device now exists
        observer.simulateDefaultDeviceChange()

        #expect(observer.isRunning == false)
        #expect(observer.isWatchingForDefaultDeviceChanges == false)
    }
}
