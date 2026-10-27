import AppKit
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// The fade between displays from the app's side (2026-10-28): when the
/// panel window fades, when it moves, what the accepted region does
/// meanwhile, and what a second move in the middle of one does.
///
/// The fader is a fake that holds every completion until the test lets it
/// finish, so each step of a trip can be looked at without an animation or
/// a clock. Where focus is comes from the `focusScreenMetrics` seam.
@MainActor
struct DisplayHandoffWiringTests {

    /// Two notchless displays either side of `NotchedDelegate`'s notched one
    /// (1470...2940 wide), touching neither.
    private static let right = ScreenMetrics(
        frame: CGRect(x: 2940, y: 200, width: 2560, height: 1440),
        safeAreaTopInset: 0, auxiliaryTopLeftWidth: 0, auxiliaryTopRightWidth: 0, menuBarHeight: 24
    )
    private static let left = ScreenMetrics(
        frame: CGRect(x: -450, y: 200, width: 1920, height: 1080),
        safeAreaTopInset: 0, auxiliaryTopLeftWidth: 0, auxiliaryTopRightWidth: 0, menuBarHeight: 24
    )

    /// The closed notch's region, panel-local, on `NotchedDelegate.metrics`.
    private static let closedRect = CGRect(x: 195, y: 222, width: 230, height: 38)
    private static let notchFrame = CGRect(x: 1895, y: 896, width: 620, height: 260)

    final class FakeFader: PanelFader {
        enum Call: Equatable {
            case fadeOut(Double)
            case fadeIn(Double, drop: CGFloat)
        }
        private(set) var calls: [Call] = []
        private var completions: [@MainActor () -> Void] = []

        func fadeOut(_ window: NSWindow, over duration: Double, then done: @escaping @MainActor () -> Void) {
            calls.append(.fadeOut(duration))
            completions.append(done)
        }

        func fadeIn(
            _ window: NSWindow, over duration: Double, droppingFrom drop: CGFloat,
            then done: @escaping @MainActor () -> Void
        ) {
            calls.append(.fadeIn(duration, drop: drop))
            completions.append(done)
        }

        /// Lets the `index`th fade asked for finish, in whatever order a
        /// test likes -- a superseded one finishing late included.
        func finish(_ index: Int) {
            guard completions.indices.contains(index) else {
                Issue.record("no fade \(index) was asked for: \(calls)")
                return
            }
            completions[index]()
        }
    }

    final class Focus {
        /// The screen the focused window is on.
        var on: ScreenMetrics = NotchedDelegate.metrics
    }

    private static let standardOut = Call.fadeOut(DisplayHandoff.standard.fadeOut)
    private static let standardIn = Call.fadeIn(DisplayHandoff.standard.fadeIn, drop: DisplayHandoff.standard.drop)
    typealias Call = FakeFader.Call

    /// Following focus on the notched display, with the fake fader and
    /// Reduce Motion off whatever the machine running the suite says.
    private func make() -> (AppDelegate, FakeFader, Focus) {
        let d = NotchedDelegate.make()
        let fader = FakeFader()
        let focus = Focus()
        d.panelFader = fader
        d.reduceMotion = { false }
        d.screenMetrics = { _ in focus.on }
        d.focusScreenMetrics = { _ in focus.on }
        return (d, fader, focus)
    }

    private func focus(_ focus: Focus, on metrics: ScreenMetrics, _ d: AppDelegate) {
        focus.on = metrics
        d.activeApplicationDidChange()
    }

    // MARK: - One trip

    /// The panel fades out where it is first; only once it is invisible does
    /// it move and take the new display's shape, then it fades in there with
    /// the drop.
    @Test func itFadesOutBeforeItMovesAndInAfter() throws {
        let (d, fader, focus) = make()
        let panel = try #require(d.panel)

        self.focus(focus, on: Self.right, d)
        #expect(fader.calls == [Self.standardOut])
        #expect(d.currentAnchor.isNotch)
        #expect(panel.frame == Self.notchFrame)

        fader.finish(0)
        #expect(d.currentAnchor.isNotch == false)
        #expect(Self.right.frame.contains(panel.frame.origin))
        #expect(fader.calls == [Self.standardOut, Self.standardIn])
    }

    /// Shrink now, grow late: the accepted region -- the hit test and the
    /// hover tracking rect -- is empty from the moment the panel starts to
    /// fade until it has faded in, then is the new shape at once. The shape
    /// was drawn whole the moment it moved, so there is no growth to wait
    /// out.
    @Test func theAcceptedRegionIsEmptyForTheWholeTrip() throws {
        let (d, fader, focus) = make()
        d.growthDelay = .milliseconds(500)
        #expect(d.acceptedRect == Self.closedRect)

        self.focus(focus, on: Self.right, d)
        #expect(d.acceptedRect == .zero)
        #expect(d.hoverView?.trackingRect == .zero)

        fader.finish(0)
        #expect(d.acceptedRect == .zero)

        fader.finish(1)
        let arrived = d.acceptedRect
        #expect(arrived != .zero)
        #expect(arrived != Self.closedRect)
        #expect(d.hoverView?.trackingRect == arrived)
        #expect(d.growthTask == nil)
    }

    /// A state that changed during the trip may still be springing open when
    /// the panel has faded in, so the region waits for it as it always does.
    @Test func aStateChangeDuringTheTripKeepsTheGrowthLag() async throws {
        let (d, fader, focus) = make()
        d.growthDelay = .milliseconds(20)

        self.focus(focus, on: Self.right, d)
        fader.finish(0)
        d.state.transition(to: .open(.shelf))
        #expect(d.acceptedRect == .zero)

        fader.finish(1)
        #expect(d.acceptedRect == .zero)
        await d.growthTask?.value
        #expect(d.acceptedRect == CGRect(origin: .zero, size: try #require(d.panel).frame.size))
    }

    /// A peek showing rides along: same state on the new display, and its
    /// region there once it has faded in.
    @Test func aPeekRidesAlong() {
        let (d, fader, focus) = make()
        d.state.transition(to: .peek(.dragTarget))
        let peekHere = d.acceptedRect

        self.focus(focus, on: Self.right, d)
        fader.finish(0)
        fader.finish(1)
        #expect(d.state.state == .peek(.dragTarget))
        #expect(d.acceptedRect != .zero)
        #expect(d.acceptedRect != peekHere)
    }

    // MARK: - A second move in the middle of one

    /// Switching on again before the first fade has finished does not queue
    /// a second trip: the one fade out, then straight to the last display
    /// asked for.
    @Test func rapidSwitchesGoStraightToTheLastDisplay() throws {
        let (d, fader, focus) = make()
        let panel = try #require(d.panel)

        self.focus(focus, on: Self.right, d)
        self.focus(focus, on: Self.left, d)
        #expect(fader.calls == [Self.standardOut])

        fader.finish(0)
        #expect(Self.left.frame.contains(panel.frame.origin))
        #expect(fader.calls == [Self.standardOut, Self.standardIn])
    }

    /// The second look after a switch asks for the trip already under way;
    /// that is not another one.
    @Test func askingForTheSameTripAgainChangesNothing() {
        let (d, fader, focus) = make()
        self.focus(focus, on: Self.right, d)
        self.focus(focus, on: Self.right, d)
        #expect(fader.calls == [Self.standardOut])
    }

    /// A move on the display it is still on, asked for before it has left --
    /// the menus it keeps clear of changing, say -- calls the trip off and is
    /// placed at once; the trip's fade finishing late takes it nowhere.
    @Test func aMoveOnItsOwnDisplayCallsOffATrip() throws {
        let (d, fader, focus) = make()
        let panel = try #require(d.panel)
        var shifted = NotchedDelegate.metrics
        shifted.auxiliaryTopLeftWidth = 600
        shifted.auxiliaryTopRightWidth = 640

        self.focus(focus, on: Self.right, d)
        self.focus(focus, on: shifted, d)
        #expect(fader.calls == [Self.standardOut, .fadeIn(DisplayHandoff.standard.fadeIn, drop: 0)])
        let placed = panel.frame
        #expect(placed != Self.notchFrame)
        #expect(NotchedDelegate.metrics.frame.contains(placed.origin))

        fader.finish(0)
        #expect(panel.frame == placed)
    }

    /// A panel built afresh mid-trip -- the launch's second chance, after a
    /// display appears -- is where it was built, and the old trip finishing
    /// late neither moves it nor leaves its region empty.
    @Test func aNewPanelEndsATripInFlight() throws {
        let (d, fader, focus) = make()
        self.focus(focus, on: Self.right, d)
        d.install(metrics: NotchedDelegate.metrics)
        let panel = try #require(d.panel)

        fader.finish(0)
        #expect(panel.frame == Self.notchFrame)
        d.state.transition(to: .peek(.dragTarget))
        #expect(d.acceptedRect != .zero)
    }

    /// Back to where it is before it has left: it fades back in on the spot,
    /// without the drop, and the superseded fade finishing late moves
    /// nothing -- it is never left invisible, nor sent where it was going.
    @Test func switchingBackBeforeItLeavesFadesItBackIn() throws {
        let (d, fader, focus) = make()
        let panel = try #require(d.panel)

        self.focus(focus, on: Self.right, d)
        self.focus(focus, on: NotchedDelegate.metrics, d)
        #expect(fader.calls == [Self.standardOut, .fadeIn(DisplayHandoff.standard.fadeIn, drop: 0)])

        fader.finish(0)
        #expect(panel.frame == Self.notchFrame)
        #expect(d.currentAnchor.isNotch)
        #expect(fader.calls.count == 2)

        fader.finish(1)
        #expect(d.acceptedRect == Self.closedRect)
    }

    /// Off to one display, called back, then off to another: the first
    /// trip's fade finishing late is not the second trip's, which moves only
    /// once its own fade has taken the window out of sight.
    @Test func aLateFadeFromACalledOffTripMovesNothing() throws {
        let (d, fader, focus) = make()
        let panel = try #require(d.panel)

        self.focus(focus, on: Self.right, d)
        self.focus(focus, on: NotchedDelegate.metrics, d)
        self.focus(focus, on: Self.left, d)
        #expect(fader.calls == [
            Self.standardOut, .fadeIn(DisplayHandoff.standard.fadeIn, drop: 0), Self.standardOut,
        ])

        fader.finish(0)
        #expect(panel.frame == Self.notchFrame)
        #expect(fader.calls.count == 3)

        fader.finish(2)
        #expect(Self.left.frame.contains(panel.frame.origin))
    }

    /// A switch while it is fading in on the new display fades it out again
    /// from there; the fade-in it cut short finishing late restores nothing.
    @Test func aSwitchDuringTheFadeInFadesOutAgain() throws {
        let (d, fader, focus) = make()
        let panel = try #require(d.panel)

        self.focus(focus, on: Self.right, d)
        fader.finish(0)
        self.focus(focus, on: NotchedDelegate.metrics, d)
        #expect(fader.calls == [Self.standardOut, Self.standardIn, Self.standardOut])

        fader.finish(1)
        #expect(d.acceptedRect == .zero)
        #expect(d.currentAnchor.isNotch == false)

        fader.finish(2)
        #expect(panel.frame == Self.notchFrame)
        fader.finish(3)
        #expect(d.acceptedRect == Self.closedRect)
    }

    // MARK: - What does not fade

    /// A move on the display it is on -- here the display changing mode --
    /// is placed at once, without a fade.
    @Test func aMoveOnTheSameDisplayDoesNotFade() throws {
        let (d, fader, focus) = make()
        let panel = try #require(d.panel)
        self.focus(focus, on: Self.right, d)
        fader.finish(0)
        fader.finish(1)
        let before = panel.frame

        var narrower = Self.right
        narrower.frame.size.width = 1920
        focus.on = narrower
        d.screenParametersDidChange()

        #expect(fader.calls.count == 2)
        #expect(panel.frame != before)
        #expect(narrower.frame.contains(panel.frame.origin))
    }

    /// Building the panel places it where it belongs, without a fade.
    @Test func theLaunchDoesNotFade() {
        let d = AppDelegate()
        let fader = FakeFader()
        d.panelFader = fader
        d.preferencesDefaults = TestDefaults.isolated()
        d.shelfTrash = TestTrash.shelf
        d.growthDelay = .zero
        d.install(metrics: NotchedDelegate.metrics)
        d.install(metrics: Self.right)
        #expect(fader.calls.isEmpty)
        #expect(d.currentAnchor.isNotch == false)
    }

    // MARK: - Full screen and Reduce Motion

    /// Full screen is checked on the display the panel has arrived on, so
    /// only once it has moved there.
    @Test func fullScreenIsCheckedOnceItHasMoved() {
        let (d, fader, focus) = make()
        var shown: [Bool] = []
        d.setPanelShown = { shown.append($0) }
        var fullScreen = false
        let watcher = FullScreenWatcher(
            center: NotificationCenter(),
            readDisplays: { [["Display Identifier": "D", "Current Space": ["type": fullScreen ? 4 : 0]]] },
            displayUUID: { "D" }
        )
        watcher.onChange = { d.applyFullScreen($0) }
        d.fullScreenWatcher = watcher
        watcher.start()

        fullScreen = true
        self.focus(focus, on: Self.right, d)
        #expect(shown.isEmpty)

        fader.finish(0)
        #expect(shown == [false])
    }

    /// Reduce Motion: the same out and in, without the drop.
    @Test func reduceMotionFadesWithoutTheDrop() {
        let (d, fader, focus) = make()
        d.reduceMotion = { true }
        self.focus(focus, on: Self.right, d)
        fader.finish(0)
        #expect(fader.calls == [
            .fadeOut(DisplayHandoff.reduced.fadeOut),
            .fadeIn(DisplayHandoff.reduced.fadeIn, drop: 0),
        ])
    }

    /// Nothing fades unless asked: a delegate a test builds moves at once,
    /// so no suite has to await a trip, and only the real launch animates.
    @Test func aFreshDelegateMovesAtOnce() {
        #expect(AppDelegate().panelFader is InstantPanelFader)
    }
}
