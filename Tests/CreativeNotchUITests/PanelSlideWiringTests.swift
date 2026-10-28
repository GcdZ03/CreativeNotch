import AppKit
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// The pill sliding along its own menu bar from the app's side (2026-10-28):
/// "Keep clear of app menus" moving it right of a long menu bar, or back.
/// When the window is asked to slide, what a second move in the middle of
/// one does, and where the accepted region and the hover tracking are while
/// it travels.
///
/// The slider is a fake that holds every completion until the test lets it
/// finish; a test stands in for the animation's progress by putting the
/// window where a real slide would have it by then, as `NSWindow`'s
/// animator does, step by step, on the main thread. The menus come from
/// `ClearOfMenusWiringTests`' fake reader.
@MainActor
struct PanelSlideWiringTests {

    /// The portrait display `ClearOfMenusWiringTests` uses: centre 540, and
    /// pid 42's menus put the pill's centre at 746, so a shift is 206pt.
    private static let portrait = ScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 1080, height: 1920),
        safeAreaTopInset: 0, auxiliaryTopLeftWidth: 0, auxiliaryTopRightWidth: 0, menuBarHeight: 30
    )
    private static let shift: CGFloat = 206
    private static let longMenus: pid_t = 42
    private static let shortMenus: pid_t = 43

    final class FakeSlider: PanelSlider {
        enum Call: Equatable {
            case slide(to: CGRect, over: Double)
            case stop(at: CGRect)
        }
        private(set) var calls: [Call] = []
        private var completions: [@MainActor () -> Void] = []

        func slide(
            _ window: NSWindow, to frame: CGRect, over duration: Double,
            then done: @escaping @MainActor () -> Void
        ) {
            calls.append(.slide(to: frame, over: duration))
            completions.append(done)
        }

        func stop(_ window: NSWindow, at frame: CGRect) {
            calls.append(.stop(at: frame))
            window.setFrame(frame, display: false)
        }

        /// Lets the `index`th slide asked for finish -- a superseded one
        /// finishing late included, as AppKit calls it when a new one
        /// replaces it.
        func finish(_ index: Int) {
            guard completions.indices.contains(index) else {
                Issue.record("no slide \(index) was asked for: \(calls)")
                return
            }
            completions[index]()
        }
    }

    private static let slideTime = PanelSlide.standard.duration

    /// The pill centred on the portrait display, keeping clear of the menus,
    /// with the fake slider and Reduce Motion off whatever the machine
    /// running the suite says.
    private func make() -> (AppDelegate, FakeSlider) {
        let d = NotchedDelegate.make()
        d.appMenuReader = ClearOfMenusWiringTests.FakeReader()
        d.screenMetrics = { _ in Self.portrait }
        d.focusScreenMetrics = { _ in Self.portrait }
        d.reduceMotion = { false }
        d.state.onSetPillClearsMenus?(true)
        d.screenParametersDidChange()
        let slider = FakeSlider()
        d.panelSlider = slider
        return (d, slider)
    }

    /// Halfway along, as the animator would have it.
    private func halfway(_ from: CGRect, _ to: CGRect) -> CGRect {
        from.offsetBy(dx: (to.minX - from.minX) / 2, dy: 0)
    }

    // MARK: - One slide

    /// An app with long menus comes forward: the window is asked to slide
    /// to its new frame, and is not put there first -- a frame set on the
    /// window outside the animation is overwritten by its next step.
    /// The geometry is the destination's at once, so a second move is
    /// decided from where the pill is going.
    @Test func aShiftClearOfTheMenusSlides() throws {
        let (d, slider) = make()
        let panel = try #require(d.panel)
        let start = panel.frame

        d.activeApplicationDidChange(pid: Self.longMenus)

        #expect(d.currentFrame.minX - start.minX == Self.shift)
        #expect(slider.calls == [.slide(to: d.currentFrame, over: Self.slideTime)])
        #expect(panel.frame == start)
    }

    /// However the animation ends -- a step short, or rounded to a point --
    /// the window ends on the frame asked for, exactly.
    @Test func theSlideEndsExactlyOnItsFrame() throws {
        let (d, slider) = make()
        let panel = try #require(d.panel)
        let start = panel.frame
        d.activeApplicationDidChange(pid: Self.longMenus)
        panel.setFrame(halfway(start, d.currentFrame).offsetBy(dx: 0.4, dy: 0), display: false)

        slider.finish(0)
        #expect(panel.frame == d.currentFrame)
    }

    /// The pill is the same picture all the way along, and the accepted
    /// region is in the window's own coordinates, so it rides with the
    /// shape: never emptied, never late.
    @Test func theRegionRidesWithTheShape() throws {
        let (d, slider) = make()
        let panel = try #require(d.panel)
        let start = panel.frame
        let region = d.acceptedRect
        #expect(region != .zero)

        d.activeApplicationDidChange(pid: Self.longMenus)
        #expect(d.acceptedRect == region)
        #expect(d.hoverView?.trackingRect == region)

        panel.setFrame(halfway(start, d.currentFrame), display: false)
        slider.finish(0)
        #expect(d.acceptedRect == region)
        #expect(d.growthTask == nil)
    }

    // MARK: - A second move in the middle of one

    /// Back to short menus halfway along: a new slide from wherever the
    /// window has got to -- not a stop at the first destination and a second
    /// slide from there -- and the first one's completion, which AppKit
    /// calls as the second replaces it, leaves the window alone.
    @Test func aSecondShiftRetargetsFromWhereItIs() throws {
        let (d, slider) = make()
        let panel = try #require(d.panel)
        let start = panel.frame
        d.activeApplicationDidChange(pid: Self.longMenus)
        let mid = halfway(start, d.currentFrame)
        panel.setFrame(mid, display: false)

        d.activeApplicationDidChange(pid: Self.shortMenus)
        #expect(d.currentFrame == start)
        #expect(slider.calls == [
            .slide(to: start.offsetBy(dx: Self.shift, dy: 0), over: Self.slideTime),
            .slide(to: start, over: Self.slideTime),
        ])

        slider.finish(0)
        #expect(panel.frame == mid)

        slider.finish(1)
        #expect(panel.frame == start)
    }

    /// A move that is no slide halfway along -- a new text size -- stops the
    /// slide and is placed at once; the slide's completion arriving after
    /// moves nothing.
    @Test func aPlacementMidSlideStopsIt() throws {
        let (d, slider) = make()
        let panel = try #require(d.panel)
        let start = panel.frame
        d.activeApplicationDidChange(pid: Self.longMenus)
        panel.setFrame(halfway(start, d.currentFrame), display: false)

        d.state.onSetTextSize?(.larger)
        let placed = d.currentFrame
        #expect(placed.size != start.size)
        #expect(slider.calls.last == .stop(at: placed))
        #expect(panel.frame == placed)

        slider.finish(0)
        #expect(panel.frame == placed)
    }

    // MARK: - The pointer

    /// The pointer resting on the pill as it starts to slide away is still on
    /// it: the window has not gone anywhere yet. Read against where the
    /// pill is going, it would count as left the moment the slide began.
    @Test func aPointerOnThePillIsStillOnItAsItStarts() throws {
        let (d, _) = make()
        let panel = try #require(d.panel)
        let tracker = try #require(d.hoverView)
        let start = panel.frame
        let onPill = CGPoint(x: start.minX + d.acceptedRect.midX, y: start.minY + d.acceptedRect.midY)
        d.pointerLocation = { onPill }
        tracker.mouseEntered(with: Self.entered())
        #expect(d.state.isHovering)

        d.activeApplicationDidChange(pid: Self.longMenus)
        #expect(d.state.isHovering)
    }

    /// Once the pill has slid out from under a still pointer, the pointer
    /// has left it. AppKit says nothing when a window moves under a pointer
    /// that does not, so the end of the slide reads it again.
    @Test func aPointerThePillSlidAwayFromHasLeftWhenItEnds() throws {
        let (d, slider) = make()
        let panel = try #require(d.panel)
        let tracker = try #require(d.hoverView)
        let start = panel.frame
        let onPill = CGPoint(x: start.minX + d.acceptedRect.midX, y: start.minY + d.acceptedRect.midY)
        d.pointerLocation = { onPill }
        tracker.mouseEntered(with: Self.entered())
        d.activeApplicationDidChange(pid: Self.longMenus)

        panel.setFrame(d.currentFrame, display: false)
        slider.finish(0)
        #expect(d.state.isHovering == false)
    }

    // MARK: - Full screen

    /// A display change that slides the pill -- the display a little
    /// narrower, its top where it was -- is still a screen change, and full
    /// screen is checked for it. `screenParametersDidChange` leaves that to
    /// `reposition` whenever something moved.
    @Test func aScreenChangeThatSlidesStillChecksFullScreen() {
        let (d, slider) = make()
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
        var narrower = Self.portrait
        narrower.frame.size.width = 1000
        d.screenMetrics = { _ in narrower }

        fullScreen = true
        d.screenParametersDidChange()
        #expect(slider.calls.count == 1)
        #expect(shown == [false])
    }

    // MARK: - Reduce Motion

    /// Reduce Motion: nothing travels. The pill is placed at once, as before.
    @Test func reduceMotionPlacesTheShiftAtOnce() throws {
        let (d, slider) = make()
        d.reduceMotion = { true }
        let panel = try #require(d.panel)
        let start = panel.frame

        d.activeApplicationDidChange(pid: Self.longMenus)
        #expect(slider.calls.isEmpty)
        #expect(panel.frame == start.offsetBy(dx: Self.shift, dy: 0))
    }

    private static func entered() -> NSEvent {
        NSEvent.enterExitEvent(
            with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil
        )!
    }
}
