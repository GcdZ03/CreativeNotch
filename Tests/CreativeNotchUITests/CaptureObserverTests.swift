import Foundation
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// The observer's lifecycle and its backstop.
///
/// The system read is injected, so no test touches CoreAudio or CoreMediaIO --
/// what is asserted is the lifecycle and the stopped-flag guard, which is the
/// part with a right answer.
@MainActor
struct CaptureObserverTests {

    /// **The line the spike was about, pinned by a source scan.**
    ///
    /// Registering on input scope succeeds with `noErr` and then never fires,
    /// while the property's value reads correctly the whole time -- so nothing
    /// short of an end-to-end test with a second application capturing would
    /// notice. That is measured, in
    /// `docs/research/2026-09-13-capture-listener-scope.md`.
    ///
    /// It cannot be pinned behaviourally here: these tests inject the system
    /// read precisely so they touch no real device. So the source is scanned,
    /// the way `ClipboardStoreTests` scans for `FileManager` and
    /// `AppDelegateTests` scans the launch path. Said plainly, because a
    /// reader who assumes the suite covers this would be wrong.
    @Test func theListenersAreRegisteredOnGlobalScope() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/CreativeNotchUI/Capture/CaptureObserver.swift")
        let text = try String(contentsOf: source, encoding: .utf8)

        // The registration blocks, isolated from the reads below them.
        let registration = try #require(text.range(of: "private func installAudioListeners"))
        let readsBegin = try #require(text.range(of: "// MARK: - Reading the system"))
        let block = String(text[registration.lowerBound..<readsBegin.lowerBound])

        #expect(block.contains("kAudioObjectPropertyScopeGlobal"),
                "the audio listener is not registered on global scope")
        #expect(block.contains("kAudioObjectPropertyScopeInput") == false,
                "the audio listener registers on input scope, which never fires")
        #expect(block.contains("kCMIOObjectPropertyScopeGlobal"),
                "the camera listener is not registered on global scope")
    }

    /// And the CMIO listener must take a real queue. The header says a NULL
    /// queue invokes the block directly on the DAL thread, which under
    /// `assumeIsolated` traps -- and in a run-loop-less harness yields zero
    /// callbacks, which reads as "CMIO does not work".
    @Test func theCameraListenerIsGivenAQueue() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/CreativeNotchUI/Capture/CaptureObserver.swift")
        let text = try String(contentsOf: source, encoding: .utf8)

        #expect(text.contains("CMIOObjectAddPropertyListenerBlock(device, &address, .main, block)"))
        #expect(text.contains("CMIOObjectAddPropertyListenerBlock(device, &address, nil") == false)
    }

    /// **The suite must never read the developer's real microphone.** Without
    /// an injected read, every wiring test would pass or fail depending on
    /// whether they happened to be on a call -- which is the worst shape a
    /// test failure can take, and it happened before this was added.
    ///
    /// Pinned by scan, because the thing being asserted is that no default
    /// construction reaches hardware, which no behavioural test can show.
    @Test func everyDelegateHelperNeutralisesTheHardwareRead() throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for name in ["AppDelegateTests.swift", "ModuleToggleTests.swift",
                     "ModuleSwitchboardTests.swift", "PreferencesWindowTests.swift",
                     "CaptureBadgeTests.swift", "NotchedDelegate.swift"] {
            let text = try String(contentsOf: tests.appendingPathComponent(name), encoding: .utf8)
            #expect(text.contains("capture?.observer.readCurrentUse"),
                    "\(name) builds a delegate whose indicator reads real hardware")
        }
    }

    @Test func startingPublishesTheCurrentStateImmediately() {
        let observer = CaptureObserver()
        observer.readCurrentUse = { CaptureUse(microphone: true) }
        var published: [CaptureUse] = []
        observer.onChange = { published.append($0) }

        observer.start()

        #expect(published == [CaptureUse(microphone: true)],
                "the indicator would stay blank until something next changed")
        observer.stop()
    }

    /// **The backstop, and it is not paranoia.** There is an unanswered radar
    /// claiming `CMIOObjectRemovePropertyListenerBlock` returns `noErr` and
    /// keeps delivering. If that reproduces, a registration count of zero means
    /// "removal was asked for" rather than "it stopped" -- the same class of
    /// failure as the media helper's activity gate. A late callback must
    /// publish nothing.
    @Test func aCallbackArrivingAfterStopPublishesNothing() {
        let observer = CaptureObserver()
        observer.readCurrentUse = { CaptureUse(camera: true) }
        var published: [CaptureUse] = []
        observer.onChange = { published.append($0) }

        observer.start()
        let afterStart = published.count
        observer.stop()

        // Exactly what a listener the system failed to remove would do.
        observer.publishForTesting()

        #expect(published.count == afterStart, "a callback after stop reached the indicator")
    }

    @Test func startingTwiceRegistersOnce() {
        let observer = CaptureObserver()
        observer.readCurrentUse = { .none }
        var publishes = 0
        observer.onChange = { _ in publishes += 1 }

        observer.start()
        let afterFirst = observer.registrationCount
        observer.start()

        #expect(observer.registrationCount == afterFirst, "listeners stacked")
        #expect(publishes == 1, "the second start republished")
        observer.stop()
    }

    @Test func stoppingRemovesEveryListener() {
        let observer = CaptureObserver()
        observer.readCurrentUse = { .none }
        observer.start()

        observer.stop()

        #expect(observer.registrationCount == 0)
    }

    /// Stopping twice is a no-op, so a switchboard leg that runs twice need not
    /// ask first.
    @Test func stoppingTwiceIsHarmless() {
        let observer = CaptureObserver()
        observer.readCurrentUse = { .none }
        observer.start()

        observer.stop()
        observer.stop()

        #expect(observer.registrationCount == 0)
    }

    /// And restarting works, or the Preferences toggle would be one-way.
    @Test func restartingPublishesAgain() {
        let observer = CaptureObserver()
        observer.readCurrentUse = { CaptureUse(camera: true) }
        var publishes = 0
        observer.onChange = { _ in publishes += 1 }

        observer.start()
        observer.stop()
        observer.start()

        #expect(publishes == 2)
        observer.stop()
    }
}
