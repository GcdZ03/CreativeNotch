import AppKit
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// "Layout" from the app's side (2026-10-24): saved and applied in one call,
/// a width change resizing the panel at once, a hidden badge leaving the
/// drawn, hit-test and hover rects in agreement, and everything restored on
/// the next launch.
///
/// `NotchedDelegate.metrics` has a 230×38 notch, wider than any real one, so
/// Compact's tab floor is visible here at four tabs as well as at five.
@MainActor
struct LayoutWiringTests {

    private static func running() -> Countdown {
        Countdown(duration: 1500, startingAt: Date())!
    }

    private func make(countdown: Countdown? = nil) -> AppDelegate {
        let d = NotchedDelegate.make(countdown: countdown)
        d.screenMetrics = { _ in NotchedDelegate.metrics }
        return d
    }

    /// A fresh launch has every default, and the panel is the size it always
    /// was.
    @Test func aFreshInstallIsTheDefaultLayout() {
        let d = make()
        #expect(d.state.layoutOptions == .default)
        #expect(d.currentFrame.size == NotchGeometry.expandedSize)
    }

    /// Wide resizes the window there and then, keeps it on the notch, and
    /// Default puts it back exactly.
    @Test func changingTheWidthResizesThePanelImmediately() throws {
        let d = make()
        let anchor = d.currentAnchor
        let panel = try #require(d.panel)

        d.state.onSetLayoutOptions?(LayoutOptions(width: .wide))
        #expect(d.state.layoutOptions.width == .wide)
        #expect(d.currentFrame.size == CGSize(width: 720, height: 260))
        #expect(d.currentFrame.midX == anchor.rect.midX)
        #expect(panel.frame == d.currentFrame)

        d.state.onSetLayoutOptions?(.default)
        #expect(d.currentFrame.size == NotchGeometry.expandedSize)
        #expect(panel.frame == d.currentFrame)
    }

    /// Width and text size compose: Wide at Larger is 720 × 1.3.
    @Test func theWidthComposesWithTheTextSize() {
        let d = make()
        d.state.onSetTextSize?(.larger)
        d.state.onSetLayoutOptions?(LayoutOptions(width: .wide))
        #expect(d.currentFrame.size == CGSize(width: 936, height: 338))
    }

    /// Compact follows the tabs: the battery tab arriving with the first
    /// power snapshot widens it, and switching the camera off narrows it --
    /// each without a screen change.
    @Test func compactFollowsTheTabsThatShow() {
        let d = make()
        d.state.onSetLayoutOptions?(LayoutOptions(width: .compact))
        // Shelf, clipboard, timer, camera: 230 + 2 × (12 + 4×34 + 3×4 + 8).
        #expect(d.currentFrame.width == 566)

        d.powerDidChange(PowerSnapshot(level: 80, source: .battery, isCharging: false, isLowPowerMode: false))
        // The battery tab makes five: 230 + 2 × (12 + 5×34 + 4×4 + 8).
        #expect(d.currentFrame.width == 642)

        d.switchboard.setEnabled(false, for: .camera)
        #expect(d.currentFrame.width == 566)
        #expect(d.panel?.frame == d.currentFrame)
    }

    /// At Default, a tab coming or going never resizes the panel.
    @Test func defaultIgnoresTheTabCount() {
        let d = make()
        d.powerDidChange(PowerSnapshot(level: 80, source: .battery, isCharging: false, isLowPowerMode: false))
        d.switchboard.setEnabled(false, for: .camera)
        #expect(d.currentFrame.size == NotchGeometry.expandedSize)
    }

    /// Hiding the timer badge takes it off the closed notch at once, and the
    /// three rects that must agree still do: what is drawn, what accepts
    /// clicks, what tracks hover.
    @Test func hidingTheTimerBadgeShrinksAllThreeRectsTogether() {
        let d = make(countdown: Self.running())
        #expect(d.currentBadgeWidth == NotchGeometry.timerBadgeWidth)

        d.state.onSetLayoutOptions?(LayoutOptions(showsTimerBadge: false))

        #expect(d.currentBadgeWidth == 0)
        let drawn = NotchRootView.drawnRect(for: d.state)
        #expect(drawn.width == d.currentAnchor.rect.width)
        #expect(drawn.size == d.acceptedRect.size)
        #expect(drawn.minX == d.acceptedRect.minX)
        #expect(d.hoverView?.trackingRect == d.acceptedRect)

        d.state.onSetLayoutOptions?(.default)
        #expect(d.currentBadgeWidth == NotchGeometry.timerBadgeWidth)
        #expect(NotchRootView.drawnRect(for: d.state).size == d.acceptedRect.size)
    }

    /// A hidden now-playing badge stays hidden through the real publish path.
    @Test func aHiddenNowPlayingBadgeStaysHiddenWhenATrackStarts() {
        let d = make()
        d.state.onSetLayoutOptions?(LayoutOptions(showsNowPlayingBadge: false))
        d.nowPlayingDidChange(TrackSnapshot(title: "Song", artist: "Band", isPlaying: true))
        #expect(d.currentBadgeWidth == 0)
        #expect(NotchRootView.drawnRect(for: d.state).size == d.acceptedRect.size)
    }

    @Test func theLayoutIsSavedAndRestoredOnTheNextLaunch() {
        let defaults = TestDefaults.isolated("layout")
        func launch() -> AppDelegate {
            let d = AppDelegate()
            d.shelfDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("shelf-\(UUID().uuidString)")
            d.shelfTrash = TestTrash.shelf
            d.screenDescriptors = { [] }
            d.announce = { _ in }
            d.preferencesDefaults = defaults
            d.playChime = { _ in }
            d.screenMetrics = { _ in nil }
            d.install(metrics: NotchedDelegate.metrics)
            return d
        }
        let chosen = LayoutOptions(
            width: .wide, corners: .round, tabsSide: .right,
            showsBattery: false, showsNowPlayingBadge: false, showsTimerBadge: false
        )
        // Held: the verb captures the delegate weakly.
        let first = launch()
        first.state.onSetLayoutOptions?(chosen)
        #expect(PreferencesStore(defaults: defaults).loadLayout() == chosen)

        let second = launch()
        #expect(second.state.layoutOptions == chosen)
        // Built at the saved width, not built at the default and grown.
        #expect(second.currentFrame.size == CGSize(width: 720, height: 260))
        #expect(second.panel?.frame.size == CGSize(width: 720, height: 260))
    }

    // MARK: - Settings

    @Test func settingsWritesThroughTheVerbAndReadsBackWhatApplied() {
        let d = make()
        let controller = PreferencesController(
            switchboard: d.switchboard, state: d.state, launchAtLogin: d.launchAtLogin
        )
        #expect(controller.layoutOptions == .default)
        LayoutRows.binding(\.tabsSide, on: controller).wrappedValue = .right
        LayoutRows.binding(\.showsBattery, on: controller).wrappedValue = false
        #expect(controller.layoutOptions.tabsSide == .right)
        #expect(controller.layoutOptions.showsBattery == false)
        #expect(d.preferencesStore.loadLayout() == controller.layoutOptions)
        #expect(LayoutRows.binding(\.tabsSide, on: controller).wrappedValue == .right)
    }

    @Test func everyChoiceHasAName() {
        #expect(PanelWidth.allCases.map(LayoutRows.title(for:)) == ["Compact", "Default", "Wide"])
        #expect(PanelCorners.allCases.map(LayoutRows.title(for:)) == ["Tight", "Default", "Round"])
        #expect(EarSide.allCases.map(LayoutRows.title(for:)) == ["Left", "Right"])
    }
}
