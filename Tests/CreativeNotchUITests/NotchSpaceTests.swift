import AppKit
import Testing
@testable import CreativeNotchUI

/// Keeping the notch still while Spaces switch (2026-10-17).
///
/// The panel joins every Space and is `.stationary`, yet a desktop swipe
/// still carried a copy out with the old Space and in with the new one, so
/// two notches showed mid-swipe. The fix hosts the panel in a Space of its
/// own above all the others, through the window server's private CGS*
/// functions.
///
/// Every test here runs against `FakeSpaceServer`. The real server would
/// create Spaces in the session of whoever runs the suite, and nothing in a
/// test run would ever tear them down.
@MainActor
struct NotchSpaceTests {

    final class FakeSpaceServer: SpaceServer {
        var nextID: UInt64 = 41
        var calls: [String] = []
        func createSpace(level: Int32) -> UInt64 {
            nextID += 1
            calls.append("create(\(level))->\(nextID)")
            return nextID
        }
        func show(_ space: UInt64) { calls.append("show(\(space))") }
        func hide(_ space: UInt64) { calls.append("hide(\(space))") }
        func add(window: Int, to space: UInt64) { calls.append("add(\(window),\(space))") }
        func remove(window: Int, from space: UInt64) { calls.append("remove(\(window),\(space))") }
        func destroy(_ space: UInt64) { calls.append("destroy(\(space))") }
    }

    // MARK: - The wrapper

    /// No server — the functions are missing on this macOS — means no Space
    /// and today's behaviour, never a crash.
    @Test func withoutTheFunctionsThereIsNoSpace() {
        #expect(NotchSpace(server: nil) == nil)
    }

    @Test func hostingCreatesShowsAndAddsOnce() throws {
        let server = FakeSpaceServer()
        let space = try #require(NotchSpace(server: server))
        space.host(windowNumber: 7)
        #expect(server.calls == ["create(\(NotchSpace.level))->42", "show(42)", "add(7,42)"])
    }

    /// The level sits above every ordinary Space, which is the whole point.
    @Test func theSpaceSitsAtTheTop() {
        #expect(NotchSpace.level == Int32.max)
    }

    @Test func hostingAnotherWindowMovesItRatherThanAddingASecond() throws {
        let server = FakeSpaceServer()
        let space = try #require(NotchSpace(server: server))
        space.host(windowNumber: 7)
        space.host(windowNumber: 9)
        #expect(server.calls.suffix(2) == ["remove(7,42)", "add(9,42)"])
        #expect(server.calls.filter { $0.hasPrefix("create") }.count == 1)
    }

    /// While the window stays on screen it is still in the Space, so a
    /// second call is a no-op.
    @Test func hostingTheSameWindowTwiceDoesNothing() throws {
        let server = FakeSpaceServer()
        let space = try #require(NotchSpace(server: server))
        space.host(windowNumber: 7)
        space.host(windowNumber: 7)
        #expect(server.calls.count == 3)
    }

    /// Ordered out, though, the window may have left the Space — and the
    /// no-op above made showing it again (back from a full-screen app) put
    /// it back on screen *outside* the Space, where a desktop swipe carries
    /// it again. Re-hosting after an order-out re-adds it, once.
    @Test func hostingAgainAfterAnOrderOutReaddsTheWindow() throws {
        let server = FakeSpaceServer()
        let space = try #require(NotchSpace(server: server))
        space.host(windowNumber: 7)
        space.windowOrderedOut()
        space.host(windowNumber: 7)
        space.host(windowNumber: 7)
        #expect(server.calls == ["create(\(NotchSpace.level))->42", "show(42)", "add(7,42)", "add(7,42)"])
    }

    /// Nothing hosted, nothing to forget: the next host is an ordinary first one.
    @Test func anOrderOutBeforeHostingChangesNothing() throws {
        let server = FakeSpaceServer()
        let space = try #require(NotchSpace(server: server))
        space.windowOrderedOut()
        space.host(windowNumber: 7)
        #expect(server.calls == ["create(\(NotchSpace.level))->42", "show(42)", "add(7,42)"])
    }

    /// A window with no number yet is not on screen; there is nothing to
    /// host.
    @Test func aWindowWithoutANumberIsSkipped() throws {
        let server = FakeSpaceServer()
        let space = try #require(NotchSpace(server: server))
        space.host(windowNumber: 0)
        #expect(server.calls.isEmpty)
    }

    /// Torn down in reverse, once. A Space left behind would sit in the
    /// window server until logout.
    @Test func tearingDownUndoesEverythingOnce() throws {
        let server = FakeSpaceServer()
        let space = try #require(NotchSpace(server: server))
        space.host(windowNumber: 7)
        space.tearDown()
        space.tearDown()
        #expect(server.calls.suffix(3) == ["remove(7,42)", "hide(42)", "destroy(42)"])
        #expect(server.calls.filter { $0.hasPrefix("destroy") }.count == 1)
    }

    @Test func tearingDownBeforeHostingTouchesNothing() throws {
        let server = FakeSpaceServer()
        let space = try #require(NotchSpace(server: server))
        space.tearDown()
        #expect(server.calls.isEmpty)
    }

    // MARK: - The real functions

    /// Looked up at runtime, not linked, so a macOS that drops them falls
    /// back instead of failing to launch. This only *resolves* them — it
    /// creates no Space — and pins that this macOS still has them.
    @Test func theWindowServerStillExportsTheFunctions() {
        #expect(SkyLightSpaceServer.load() != nil)
    }

    // MARK: - The app

    /// Hosting happens at launch, after the panel is on screen, and leaving
    /// tears it down. Driven with the fake through the delegate's seam.
    @Test func theDelegateHostsThePanelAndTearsDownOnQuit() throws {
        let delegate = NotchedDelegate.make()
        let server = FakeSpaceServer()
        delegate.makeSpaceServer = { server }
        let panel = try #require(delegate.panel)

        delegate.hostPanelInFixedSpace()
        #expect(server.calls.contains("add(\(panel.windowNumber),42)") || panel.windowNumber <= 0)

        delegate.applicationWillTerminate(Notification(name: .init("terminate")))
        if panel.windowNumber > 0 {
            #expect(server.calls.last == "destroy(42)")
        }
    }

    /// The default seam is the real server, but nothing calls it unless the
    /// app launches: tests build the delegate through `install`, which must
    /// never create a Space.
    @Test func installingDoesNotCreateASpace() {
        let delegate = NotchedDelegate.make()
        #expect(delegate.fixedSpace == nil)
    }
}
