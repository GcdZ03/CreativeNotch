import AppKit
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// The anchor changing on the display it is on, from the app's side
/// (2026-10-28): the notch becoming a pill when the built-in changes to a
/// mode without the notch's band, or back, and the pill going between the
/// menu bar and below it when the menu bar is hidden or shown. When the shape
/// morphs and from where, when it fades on the spot instead, and what the
/// accepted region does meanwhile.
///
/// The morpher and the fader are fakes that hold every completion until the
/// test lets it finish, and the clock a morph cut short is measured on is the
/// test's. The displays come from the `screenMetrics` seam.
@MainActor
struct AnchorMorphWiringTests {

    /// `NotchedDelegate`'s display in a mode without the notch's band: the
    /// same bottom edge, the top 38pt lower, a 30pt menu bar the pill sits in.
    private static let belowNotch = ScreenMetrics(
        frame: CGRect(x: 1470, y: 200, width: 1470, height: 918),
        safeAreaTopInset: 0, auxiliaryTopLeftWidth: 0, auxiliaryTopRightWidth: 0, menuBarHeight: 30
    )
    /// The closed notch on `NotchedDelegate.metrics`, panel-local, and its
    /// window.
    private static let closedNotch = CGRect(x: 195, y: 222, width: 230, height: 38)
    private static let notchFrame = CGRect(x: 1895, y: 896, width: 620, height: 260)
    /// The idle capsule on `belowNotch`, carried into the notch's window: 2pt
    /// under the top of the display, as it was.
    private static let pillInNotchWindow = CGRect(x: 290, y: 232, width: 40, height: 26)

    /// `PanelSlideWiringTests`' portrait display with its 30pt menu bar, and
    /// with the menu bar hidden.
    private static let portrait = ScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 1080, height: 1920),
        safeAreaTopInset: 0, auxiliaryTopLeftWidth: 0, auxiliaryTopRightWidth: 0, menuBarHeight: 30
    )
    private static let portraitNoMenuBar = ScreenMetrics(
        frame: portrait.frame,
        safeAreaTopInset: 0, auxiliaryTopLeftWidth: 0, auxiliaryTopRightWidth: 0, menuBarHeight: 0
    )
    /// The capsule in the menu bar, and hanging below the top with the menu
    /// bar hidden carried into the in-bar window, 6pt lower: panel-local.
    private static let inBar = CGRect(x: 290, y: 234, width: 40, height: 26)
    private static let belowBarInBarWindow = CGRect(x: 290, y: 222, width: 40, height: 32)
    /// The capsule hanging below the top in its own window, with the menu
    /// bar hidden.
    private static let belowBar = CGRect(x: 290, y: 228, width: 40, height: 32)

    /// The portrait display with a 36pt menu bar: the pill 6pt taller from
    /// the same top, so its window does not move and holds the old capsule.
    private static let portraitTallerMenuBar = ScreenMetrics(
        frame: portrait.frame,
        safeAreaTopInset: 0, auxiliaryTopLeftWidth: 0, auxiliaryTopRightWidth: 0, menuBarHeight: 36
    )
    private static let tallerInBar = CGRect(x: 290, y: 228, width: 40, height: 32)

    final class FakeMorpher: PanelMorpher {
        private(set) var calls: [Double] = []
        private var completions: [@MainActor () -> Void] = []

        func morph(over duration: Double, then done: @escaping @MainActor () -> Void) {
            calls.append(duration)
            completions.append(done)
        }

        /// Lets the `index`th morph finish -- a superseded one late included.
        func finish(_ index: Int) {
            guard completions.indices.contains(index) else {
                Issue.record("no morph \(index) was asked for: \(calls)")
                return
            }
            completions[index]()
        }
    }

    final class Display {
        var metrics: ScreenMetrics
        init(_ metrics: ScreenMetrics) { self.metrics = metrics }
    }

    final class Clock {
        var now: Double = 100
    }

    private typealias FakeFader = DisplayHandoffWiringTests.FakeFader

    /// A delegate shown on `start`, then given the fakes, with Reduce Motion
    /// off whatever the machine running the suite says.
    private func make(on start: ScreenMetrics) -> (AppDelegate, FakeMorpher, FakeFader, Display, Clock) {
        let d = NotchedDelegate.make()
        let display = Display(start)
        let clock = Clock()
        d.reduceMotion = { false }
        d.screenMetrics = { _ in display.metrics }
        d.focusScreenMetrics = { _ in display.metrics }
        d.screenParametersDidChange()
        let morpher = FakeMorpher()
        let fader = FakeFader()
        d.panelMorpher = morpher
        d.panelFader = fader
        d.mediaTime = { clock.now }
        return (d, morpher, fader, display, clock)
    }

    private func change(_ display: Display, to metrics: ScreenMetrics, _ d: AppDelegate) {
        display.metrics = metrics
        d.screenParametersDidChange()
    }

    // MARK: - The pill becoming the notch

    /// Into a notched mode: the window is where the notch's goes at once, and
    /// the shape starts where the pill was on the display -- inside that
    /// window, 2pt under its top -- and morphs to the notch.
    @Test func thePillBecomingTheNotchMorphsInsideTheWindow() throws {
        let (d, morpher, fader, display, _) = make(on: Self.belowNotch)
        let panel = try #require(d.panel)
        #expect(d.currentAnchor.isNotch == false)

        change(display, to: NotchedDelegate.metrics, d)
        #expect(d.currentAnchor.isNotch)
        #expect(panel.frame == Self.notchFrame)
        #expect(d.state.morph?.morph == AnchorMorph(from: Self.pillInNotchWindow))
        #expect(morpher.calls == [AnchorMorph.standardDuration])
        #expect(fader.calls.isEmpty)

        morpher.finish(0)
        #expect(d.state.morph == nil)
    }

    /// The region is what the two shapes share while it morphs -- every step
    /// of the morph covers it -- then the new shape at once when it is
    /// there, with no growth lag: there is no spring left to wait for.
    @Test func theRegionIsWhatBothShapesShareWhileItMorphs() throws {
        let (d, morpher, _, display, _) = make(on: Self.portraitNoMenuBar)
        d.growthDelay = .milliseconds(500)

        change(display, to: Self.portrait, d)
        #expect(d.state.morph?.morph == AnchorMorph(from: Self.belowBarInBarWindow))
        let shared = Self.belowBarInBarWindow.intersection(Self.inBar)
        #expect(d.acceptedRect == shared)
        #expect(d.hoverView?.trackingRect == shared)

        morpher.finish(0)
        #expect(d.acceptedRect == Self.inBar)
        #expect(d.hoverView?.trackingRect == Self.inBar)
        #expect(d.growthTask == nil)
    }

    // MARK: - Fading on the spot

    /// Into a mode without the notch's band: the pill's window hangs 2pt
    /// lower than the notch's top, which would cut the notch on the first
    /// frame. The panel fades out where it is, takes the pill's shape, and
    /// fades back in without a drop; the region is empty meanwhile.
    @Test func theNotchBecomingAPillFadesOnTheSpot() throws {
        let (d, morpher, fader, display, _) = make(on: NotchedDelegate.metrics)
        let panel = try #require(d.panel)

        change(display, to: Self.belowNotch, d)
        #expect(fader.calls == [.fadeOut(DisplayHandoff.onTheSpot.fadeOut)])
        #expect(d.currentAnchor.isNotch)
        #expect(panel.frame == Self.notchFrame)
        #expect(d.acceptedRect == .zero)

        fader.finish(0)
        #expect(d.currentAnchor.isNotch == false)
        #expect(fader.calls.last == .fadeIn(DisplayHandoff.onTheSpot.fadeIn, drop: 0))
        #expect(d.acceptedRect == .zero)

        fader.finish(1)
        #expect(d.acceptedRect != .zero)
        #expect(morpher.calls.isEmpty)
        #expect(d.state.morph == nil)
    }

    /// There and back: the pill a fade on the spot left on the display in
    /// its new mode was placed on that display, not the one the trip set out
    /// from. Back into the notched mode, it morphs from 2pt under the top,
    /// where it is -- not 38pt lower, measured from a top that has moved.
    @Test func aMorphAfterAFadeOnTheSpotStartsFromTheDisplayItArrivedOn() {
        let (d, morpher, fader, display, _) = make(on: NotchedDelegate.metrics)
        change(display, to: Self.belowNotch, d)
        fader.finish(0)
        fader.finish(1)
        #expect(d.currentAnchor.isNotch == false)

        change(display, to: NotchedDelegate.metrics, d)
        #expect(d.state.morph?.morph == AnchorMorph(from: Self.pillInNotchWindow))
        #expect(morpher.calls.count == 1)
    }

    /// Reduce Motion: a change of shape fades on the spot even where it
    /// could morph. Nothing travels.
    @Test func reduceMotionFadesAChangeOfShape() {
        let (d, morpher, fader, display, _) = make(on: Self.portraitNoMenuBar)
        d.reduceMotion = { true }

        change(display, to: Self.portrait, d)
        #expect(morpher.calls.isEmpty)
        #expect(d.state.morph == nil)
        #expect(fader.calls == [.fadeOut(DisplayHandoff.onTheSpot.fadeOut)])
    }

    // MARK: - Interruptions

    /// The panel opening while the shape morphs ends the morph: the state's
    /// spring takes the shape from where it is, and the region trails that
    /// spring as it does any other. The morph's completion arriving after
    /// changes nothing.
    @Test func aStateChangeEndsTheMorph() throws {
        let (d, morpher, _, display, _) = make(on: Self.portraitNoMenuBar)
        d.growthDelay = .milliseconds(500)
        change(display, to: Self.portrait, d)
        let shared = d.acceptedRect

        d.state.transition(to: .open(.shelf))
        #expect(d.state.morph == nil)
        #expect(d.acceptedRect == shared)
        #expect(d.growthTask != nil)

        morpher.finish(0)
        #expect(d.acceptedRect == shared)
    }

    /// The menu bar changing height again halfway through: the second morph
    /// starts where the shape has got to, eased half way, not where the
    /// first one was going. The first one's completion arriving late leaves
    /// the second alone.
    @Test func aSecondChangeMorphsFromWhereTheShapeHasGot() throws {
        let (d, morpher, _, display, clock) = make(on: Self.portraitNoMenuBar)
        change(display, to: Self.portrait, d)
        clock.now += AnchorMorph.standardDuration / 2

        var shorter = Self.portrait
        shorter.menuBarHeight = 24
        change(display, to: shorter, d)
        let halfway = AnchorMorph.rect(from: Self.belowBarInBarWindow, to: Self.inBar, progress: 0.5)
        #expect(halfway != Self.inBar)
        #expect(d.state.morph?.morph == AnchorMorph(from: halfway))
        #expect(morpher.calls.count == 2)

        let second = try #require(d.state.morph)
        let region = d.acceptedRect
        morpher.finish(0)
        #expect(d.state.morph == second)
        #expect(d.acceptedRect == region)
    }

    /// Keeping clear of the menus while it morphs: the window slides, and
    /// the shape goes on morphing inside it, where it is in the window being
    /// the same all the way along.
    @Test func aSlideDuringTheMorphKeepsIt() throws {
        let (d, _, _, display, _) = make(on: Self.portraitNoMenuBar)
        d.appMenuReader = ClearOfMenusWiringTests.FakeReader()
        d.state.onSetPillClearsMenus?(true)
        let slider = PanelSlideWiringTests.FakeSlider()
        d.panelSlider = slider
        change(display, to: Self.portrait, d)
        let morph = try #require(d.state.morph)

        d.activeApplicationDidChange(pid: 42)
        #expect(slider.calls.count == 1)
        #expect(d.state.morph == morph)
    }

    /// A morph cutting a slide short starts where the shape is on screen:
    /// in the window as far as it has slid, not in the one it was sliding
    /// to. The window is stopped on its new frame, and the shape morphs
    /// from 206pt back along the bar, where the window still was.
    @Test func aMorphDuringASlideStartsWhereTheWindowHasGot() throws {
        let (d, _, _, display, _) = make(on: Self.portrait)
        let panel = try #require(d.panel)
        d.appMenuReader = ClearOfMenusWiringTests.FakeReader()
        d.state.onSetPillClearsMenus?(true)
        let slider = PanelSlideWiringTests.FakeSlider()
        d.panelSlider = slider
        d.activeApplicationDidChange(pid: 42)
        #expect(slider.calls.count == 1)
        #expect(panel.frame.minX == d.currentFrame.minX - 206)

        change(display, to: Self.portraitTallerMenuBar, d)
        #expect(d.state.morph?.morph == AnchorMorph(from: Self.inBar.offsetBy(dx: -206, dy: 0)))
        #expect(slider.calls.last == .stop(at: d.currentFrame))
        #expect(panel.frame == d.currentFrame)
    }

    /// A morph calling a fade on the spot off: the window fades back in
    /// where it is while the shape morphs, and the fade can be over first.
    /// The region is then what the two shapes share, as for any morph, and
    /// the new shape whole only once the morph is -- not at the end of the
    /// fade, while the shape is still on its way.
    @Test func aFadeInOverBeforeTheMorphKeepsTheSharedRegion() throws {
        let (d, morpher, fader, display, _) = make(on: Self.portrait)
        change(display, to: Self.portraitNoMenuBar, d)
        #expect(fader.calls == [.fadeOut(DisplayHandoff.onTheSpot.fadeOut)])

        change(display, to: Self.portraitTallerMenuBar, d)
        #expect(d.state.morph?.morph == AnchorMorph(from: Self.inBar))
        #expect(fader.calls.count == 2)
        #expect(d.acceptedRect == .zero)

        fader.finish(1)
        #expect(d.acceptedRect == Self.inBar)
        #expect(d.hoverView?.trackingRect == Self.inBar)

        morpher.finish(0)
        #expect(d.acceptedRect == Self.tallerInBar)
    }

    /// The other way: a morph whose time is up while a fade on the spot is
    /// under way leaves the region empty. The window is fading out, and it
    /// gives the region back once it has faded in.
    @Test func aMorphOverDuringAFadeLeavesTheRegionEmpty() throws {
        let (d, morpher, fader, display, clock) = make(on: Self.portraitNoMenuBar)
        change(display, to: Self.portrait, d)
        clock.now += AnchorMorph.standardDuration

        change(display, to: Self.portraitNoMenuBar, d)
        #expect(fader.calls == [.fadeOut(DisplayHandoff.onTheSpot.fadeOut)])
        morpher.finish(0)
        #expect(d.state.morph == nil)
        #expect(d.acceptedRect == .zero)

        fader.finish(0)
        #expect(d.acceptedRect == .zero)
        fader.finish(1)
        #expect(d.acceptedRect == Self.belowBar)
    }

    /// A fresh panel is placed where it belongs and drawn there: a morph
    /// the last one was in is over, even when the geometry is the same.
    @Test func aNewPanelEndsAMorph() {
        let (d, _, _, display, _) = make(on: Self.portraitNoMenuBar)
        change(display, to: Self.portrait, d)
        #expect(d.state.morph != nil)

        d.install(metrics: Self.portrait)
        #expect(d.state.morph == nil)
        #expect(d.acceptedRect == Self.inBar)
    }

    // MARK: - Around it

    /// A morph moves the window, so it is a move like any other: full
    /// screen is checked for it, as `screenParametersDidChange` leaves to
    /// `reposition` whenever something moved.
    @Test func aMorphStillChecksFullScreen() {
        let (d, morpher, _, display, _) = make(on: Self.portraitNoMenuBar)
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
        change(display, to: Self.portrait, d)
        #expect(morpher.calls.count == 1)
        #expect(shown == [false])
    }

    /// A new text size keeps the anchor and grows the window around it: the
    /// closed shape does not move on screen, and it is placed at once --
    /// neither morphed nor faded.
    @Test func aNewTextSizeIsPlacedAtOnce() throws {
        let (d, morpher, fader, _, _) = make(on: Self.portrait)
        let panel = try #require(d.panel)
        let before = panel.frame

        d.state.onSetTextSize?(.larger)
        #expect(panel.frame != before)
        #expect(panel.frame == d.currentFrame)
        #expect(morpher.calls.isEmpty)
        #expect(fader.calls.isEmpty)
        #expect(d.state.morph == nil)
    }

    /// The view starts the shape where the morph says, in its own top-left
    /// space: `from` is bottom-left, as the region is.
    @Test func theViewStartsTheShapeWhereTheMorphSays() throws {
        let (d, _, _, display, _) = make(on: Self.portraitNoMenuBar)
        change(display, to: Self.portrait, d)
        let start = try #require(NotchRootView.morphStart(for: d.state))
        // 260 - (222 + 32): the window's height less the top of `from`.
        #expect(start == CGRect(x: 290, y: 6, width: 40, height: 32))
    }
}
