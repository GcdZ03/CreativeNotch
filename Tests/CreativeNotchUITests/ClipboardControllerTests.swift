import AppKit
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// The wiring between the poller, the activity gate and the ring.
///
/// Shaped after `HUDController`: the sources are dumb, and everything that
/// connects them lives in one object that can be built in a test.
@MainActor
struct ClipboardControllerTests {

    private struct Harness {
        let controller: ClipboardController
        let pasteboard: NSPasteboard

        /// `clearContents()` is what bumps `changeCount`; `setString`
        /// alone does not. See `ClipboardPollerTests.Harness.copy`.
        func copy(_ string: String) {
            pasteboard.clearContents()
            pasteboard.setString(string, forType: .string)
        }
    }

    private func makeHarness() -> Harness {
        let pb = NSPasteboard(name: NSPasteboard.Name("CreativeNotchCtlTest-\(UUID().uuidString)"))
        pb.clearContents()

        let controller = ClipboardController(store: ClipboardStore(), pasteboard: pb)
        controller.poller.scheduleTimer = { _, _ in nil }
        controller.poller.cancelTimer = { _ in }
        controller.poller.isLowPowerMode = { false }

        return Harness(controller: controller, pasteboard: pb)
    }

    @Test func aCapturedChangeReachesTheRing() {
        let h = makeHarness()
        h.controller.start()

        h.copy("captured")
        h.controller.poller.tick(now: 1)

        #expect(h.controller.store.entries.map(\.content) == [.text("captured")])
    }

    @Test func lockingTheScreenStopsEntriesReachingTheRing() {
        let h = makeHarness()
        h.controller.start()
        h.controller.activity.handle(.screenLocked)

        h.copy("while locked")
        h.controller.poller.tick(now: 1)

        #expect(h.controller.store.entries.isEmpty)
    }

    /// The gate is wired, not merely present: an unlock has to reach the
    /// poller for polling to resume at all.
    @Test func unlockingResumesCapture() {
        let h = makeHarness()
        h.controller.start()
        h.controller.activity.handle(.screenLocked)
        h.controller.activity.handle(.screenUnlocked)

        h.copy("after unlock")
        h.controller.poller.tick(now: 2)

        #expect(h.controller.store.entries.map(\.content) == [.text("after unlock")])
    }

    @Test func stoppingStopsBoth() {
        let h = makeHarness()
        h.controller.start()
        h.controller.stop()

        #expect(h.controller.activity.tokenCount == 0)

        h.copy("after stop")
        h.controller.poller.tick(now: 1)
        #expect(h.controller.store.entries.isEmpty)
    }

    // MARK: - Paste-back

    @Test func pastingWritesTheEntryToThePasteboard() throws {
        let h = makeHarness()
        let entry = try #require(h.controller.store.record(.text("paste me"), now: Date()))

        h.controller.paste(entry)

        #expect(h.pasteboard.string(forType: .string) == "paste me")
    }

    /// The paste-back loop, resolved by promotion rather than by a special
    /// case. Writing bumps `changeCount`, the poller sees its own write,
    /// and the entry it finds is the one already in the ring — so the ring
    /// keeps one copy, not two.
    @Test func pastingBackDoesNotDuplicateTheEntry() throws {
        let h = makeHarness()
        h.controller.start()
        h.controller.store.record(.text("A"), now: Date(timeIntervalSince1970: 0))
        h.controller.store.record(.text("B"), now: Date(timeIntervalSince1970: 1))

        let a = try #require(h.controller.store.entries.last)
        h.controller.paste(a)
        h.controller.poller.tick(now: 2)

        #expect(h.controller.store.entries.count == 2)
        #expect(h.controller.store.entries.first?.content == .text("A"))
        #expect(h.controller.store.entries.first?.id == a.id)
    }

    @Test func pastingAnImageWritesImageData() throws {
        let h = makeHarness()
        let data = Data([0x89, 0x50, 0x4E, 0x47])
        let entry = try #require(h.controller.store.record(.image(data, ext: "png"), now: Date()))

        h.controller.paste(entry)

        #expect(h.pasteboard.data(forType: .png) == data)
    }
}
