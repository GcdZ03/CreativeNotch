import AppKit
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// DisplayServices is private but not permission-gated. The spike confirmed
/// registration succeeds and the notification fires once per change — but
/// also that the callback's display-ID argument is **0**, so reading with
/// it returns status 1000 and writes nothing. `CGMainDisplayID()` is what
/// works.
@MainActor
struct BrightnessObserverTests {

    @Test func aFreshObserverIsNotRunning() {
        #expect(BrightnessObserver().isRunning == false)
    }

    @Test func startingAndStoppingIsIdempotent() {
        let observer = BrightnessObserver()
        observer.start()
        observer.start()
        #expect(observer.isRunning)
        observer.stop()
        observer.stop()
        #expect(observer.isRunning == false)
    }

    @Test func theCurrentLevelIsAUnitValueOrUnavailable() {
        if let level = BrightnessObserver().currentLevel() {
            #expect(level >= 0 && level <= 1)
        }
        // An external-display-only machine legitimately has no readable
        // built-in brightness; nil is a valid answer.
    }

    /// The framework has to load and the symbols resolve, or the whole
    /// module is inert. Cheap to assert, and it fails loudly if a future
    /// macOS drops them.
    @Test func theDisplayServicesSymbolsResolve() {
        #expect(BrightnessObserver.symbolsAvailable)
    }

    /// Mirrors the bug Task 3 found in `VolumeObserver`: reading must not
    /// depend on having called `start()` first. `currentLevel()` here
    /// always resolves `CGMainDisplayID()` fresh, so this should hold
    /// regardless — but a regression that made it depend on instance state
    /// populated only by `start()` would show up as `before` and `after`
    /// disagreeing on nil-ness, which a bare "nil is allowed" check alone
    /// would not catch.
    @Test func theLevelReadsTheSameBeforeAndAfterStarting() {
        let observer = BrightnessObserver()
        let before = observer.currentLevel()
        observer.start()
        let after = observer.currentLevel()
        observer.stop()
        #expect((before == nil) == (after == nil))
    }

    /// The brief's original `stop()` built a *fresh* `@convention(c)`
    /// closure literal to pass to
    /// `DisplayServicesUnregisterForBrightnessChangeNotifications`. Two
    /// closure literals are not guaranteed to share a function pointer, so
    /// unregistration could silently fail to match what `start()`
    /// registered — leaking the listener while `isRunning` still flips to
    /// `false`. No live brightness change is needed to prove this: it's a
    /// Swift-level fact about which pointer got passed where, exposed only
    /// for this test via `lastRegisteredCallback` / `lastUnregisteredCallback`.
    @Test func stopUnregistersTheSameCallbackPointerThatStartRegistered() {
        let observer = BrightnessObserver()
        observer.start()
        guard observer.isRunning else { return } // no symbols / can't register on this host
        let registered = BrightnessObserver.lastRegisteredCallback
        observer.stop()
        let unregistered = BrightnessObserver.lastUnregisteredCallback
        #expect(registered != nil)
        #expect(registered == unregistered)
    }
}
