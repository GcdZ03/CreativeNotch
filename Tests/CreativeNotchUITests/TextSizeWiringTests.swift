import AppKit
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// "Text size" from the app's side (2026-10-24): saved and applied in one
/// call, the panel resized at once, and restored on the next launch.
@MainActor
struct TextSizeWiringTests {

    /// A fresh launch is the default size, and the panel is the size it
    /// always was.
    @Test func aFreshInstallIsTheDefaultSize() {
        let d = NotchedDelegate.make()
        #expect(d.state.textSize == .standard)
        #expect(d.currentFrame.size == NotchGeometry.expandedSize)
    }

    /// Applying a size grows the window there and then -- not on the next
    /// screen change -- and keeps it on the notch.
    @Test func changingTheSizeResizesThePanelImmediately() throws {
        let d = NotchedDelegate.make()
        d.screenMetrics = { _ in NotchedDelegate.metrics }
        let anchor = d.currentAnchor

        d.state.onSetTextSize?(.larger)

        #expect(d.state.textSize == .larger)
        #expect(d.currentFrame.size == CGSize(width: 806, height: 338))
        #expect(d.currentFrame.midX == anchor.rect.midX)
        #expect(d.currentFrame.maxY == anchor.rect.maxY)
        let panel = try #require(d.panel)
        #expect(panel.frame == d.currentFrame)

        d.state.onSetTextSize?(.standard)
        #expect(d.currentFrame.size == NotchGeometry.expandedSize)
        #expect(panel.frame == d.currentFrame)
    }

    /// A screen change places the panel at the chosen size, not the default.
    @Test func aScreenChangeKeepsTheChosenSize() {
        let d = NotchedDelegate.make()
        d.screenMetrics = { _ in NotchedDelegate.metrics }
        d.state.onSetTextSize?(.large)
        d.screenParametersDidChange()
        #expect(d.currentFrame.size == CGSize(width: 713, height: 299))
    }

    @Test func theSizeIsSavedAndRestoredOnTheNextLaunch() {
        let defaults = TestDefaults.isolated("text-size")
        let first = AppDelegate()
        first.shelfDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("shelf-\(UUID().uuidString)")
        first.shelfTrash = TestTrash.shelf
        first.screenDescriptors = { [] }
        first.announce = { _ in }
        first.preferencesDefaults = defaults
        first.playChime = { _ in }
        first.screenMetrics = { _ in nil }
        first.install(metrics: NotchedDelegate.metrics)
        first.state.onSetTextSize?(.larger)
        #expect(PreferencesStore(defaults: defaults).textSize == .larger)

        let second = AppDelegate()
        second.shelfDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("shelf-\(UUID().uuidString)")
        second.shelfTrash = TestTrash.shelf
        second.screenDescriptors = { [] }
        second.announce = { _ in }
        second.preferencesDefaults = defaults
        second.playChime = { _ in }
        second.install(metrics: NotchedDelegate.metrics)
        #expect(second.state.textSize == .larger)
        // Built at the saved size, not built small and grown afterwards.
        #expect(second.currentFrame.size == CGSize(width: 806, height: 338))
        #expect(second.panel?.frame.size == CGSize(width: 806, height: 338))
    }

    // MARK: - Settings

    @Test func settingsWritesThroughTheVerbAndReadsBackWhatApplied() {
        let d = NotchedDelegate.make()
        let controller = PreferencesController(
            switchboard: d.switchboard, state: d.state, launchAtLogin: d.launchAtLogin
        )
        #expect(controller.textSize == .standard)
        controller.setTextSize(.large)
        #expect(controller.textSize == .large)
        #expect(d.preferencesStore.textSize == .large)
    }

    @Test func everySizeHasAName() {
        #expect(TextSizeRow.title(for: .standard) == "Default")
        #expect(TextSizeRow.title(for: .large) == "Large")
        #expect(TextSizeRow.title(for: .larger) == "Larger")
    }
}
