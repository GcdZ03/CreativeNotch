import AppKit
import Foundation
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// A sampler that never shows a loupe: it records that it was asked, and the
/// test decides when -- and with what -- the pick finishes.
@MainActor
final class FakeColorSampler: ColorSampling {
    private(set) var requests = 0
    private var pending: [(SampledColor?) -> Void] = []

    func sample(_ completion: @escaping @MainActor (SampledColor?) -> Void) {
        requests += 1
        pending.append(completion)
    }

    /// Finishes the oldest pick still open, as a click (a colour) or Esc (nil).
    func finish(with color: SampledColor?) {
        guard !pending.isEmpty else { return }
        pending.removeFirst()(color)
    }
}

/// The colour picker, through the delegate the app builds (2026-10-24).
///
/// Every assertion is against what reached the pasteboard, the panel or the
/// sampler -- never only a stored flag -- for the reason
/// `ModuleSwitchboardTests` gives. The pasteboard is a uniquely named one per
/// delegate, so nothing here touches the developer's real clipboard.
@MainActor
struct ColorPickerWiringTests {

    static let blue = SampledColor(red8: 58, green8: 123, blue8: 213)
    static let red = SampledColor(red8: 255, green8: 0, blue8: 0)

    private func make() -> (AppDelegate, FakeColorSampler) {
        let sampler = FakeColorSampler()
        let delegate = AppDelegate()
        delegate.shelfTrash = TestTrash.shelf
        delegate.preferencesDefaults = TestDefaults.isolated("color-picker")
        delegate.growthDelay = .zero
        delegate.playChime = { _ in }
        delegate.performHaptic = {}
        delegate.announce = { _ in }
        delegate.pointerLocation = { CGPoint(x: -10_000, y: -10_000) }
        delegate.screenDescriptors = { [] }
        delegate.colorSampler = sampler
        delegate.install(metrics: NotchedDelegate.metrics)
        return (delegate, sampler)
    }

    private func copied(_ delegate: AppDelegate) -> String? {
        delegate.colorPasteboard.string(forType: .string)
    }

    // The verbs as the view calls them. Unwrapped into a local first:
    // calling `try #require(verb)()` in one expression crashes the 6.3
    // type checker.
    private func pick(_ delegate: AppDelegate) throws {
        let verb = try #require(delegate.state.onPickColor)
        verb()
    }

    private func copy(_ color: SampledColor, in delegate: AppDelegate) throws {
        let verb = try #require(delegate.state.onCopyColor)
        verb(color)
    }

    private func setFormat(_ format: ColorFormat, in delegate: AppDelegate) throws {
        let verb = try #require(delegate.state.onSetColorFormat)
        verb(format)
    }

    // MARK: - Picking

    /// The dropper closes the panel so the whole screen -- the band under the
    /// panel included -- can be sampled, and asks the sampler exactly once.
    @Test func theDropperClosesThePanelAndStartsTheSampler() throws {
        let (delegate, sampler) = make()
        delegate.state.transition(to: .open(.clipboard))

        try pick(delegate)

        #expect(delegate.state.state == .closed)
        #expect(sampler.requests == 1)
    }

    /// A pick lands on the pasteboard as hex by default, joins the history,
    /// and the panel comes back on the tab it was on with the result showing.
    @Test func aPickIsCopiedAsHexAndShownInThePanel() throws {
        let (delegate, sampler) = make()
        delegate.state.transition(to: .open(.timer))
        try pick(delegate)

        sampler.finish(with: Self.blue)

        #expect(copied(delegate) == "#3A7BD5")
        #expect(delegate.state.recentColors == [Self.blue])
        #expect(delegate.state.pickedColor == Self.blue)
        #expect(delegate.state.state == .open(.timer))
    }

    /// Reopening after a pick is ambient: the person is working in another
    /// app, and the confirmation must not take their keystrokes.
    @Test func theReopenAfterAPickDoesNotTakeTheKeyboard() throws {
        let (delegate, sampler) = make()
        delegate.state.transition(to: .open(.clipboard), openedBy: .tap)
        try pick(delegate)
        sampler.finish(with: Self.blue)

        let reason = try #require(delegate.state.openReason)
        #expect(reason.isExplicit == false)
    }

    /// Esc in the loupe copies nothing and shows no result, but still puts the
    /// panel back where it was.
    @Test func aCancelledPickCopiesNothing() throws {
        let (delegate, sampler) = make()
        delegate.colorPasteboard.clearContents()
        delegate.colorPasteboard.setString("before", forType: .string)
        delegate.state.transition(to: .open(.timer))
        try pick(delegate)

        sampler.finish(with: nil)

        #expect(copied(delegate) == "before")
        #expect(delegate.state.recentColors.isEmpty)
        #expect(delegate.state.pickedColor == nil)
        #expect(delegate.state.state == .open(.timer))
    }

    /// A second click while the loupe is up does not stack a second loupe.
    @Test func aSecondPickWhileSamplingIsIgnored() throws {
        let (delegate, sampler) = make()
        delegate.state.transition(to: .open(.timer))
        try pick(delegate)
        try pick(delegate)
        #expect(sampler.requests == 1)

        sampler.finish(with: Self.blue)
        try pick(delegate)
        #expect(sampler.requests == 2)
    }

    @Test func aPickIsAnnouncedWithItsName() throws {
        let (delegate, sampler) = make()
        var said: [String] = []
        delegate.announce = { said.append($0) }
        delegate.state.transition(to: .open(.timer))
        try pick(delegate)
        sampler.finish(with: Self.blue)
        #expect(said == ["Copied blue, #3A7BD5"])
    }

    // MARK: - The strip and the history

    /// The result belongs to the opening it was shown in: closing the panel
    /// takes it away, so the next opening is the pane as it always was.
    @Test func leavingThePanelHidesTheResult() throws {
        let (delegate, sampler) = make()
        delegate.state.transition(to: .open(.timer))
        try pick(delegate)
        sampler.finish(with: Self.blue)
        #expect(delegate.state.pickedColor != nil)

        delegate.state.transition(to: .closed)

        #expect(delegate.state.pickedColor == nil)
        #expect(delegate.state.recentColors == [Self.blue], "the history outlives the strip")
    }

    /// Switching tabs is the same opening, so the strip stays.
    @Test func switchingTabsKeepsTheResult() throws {
        let (delegate, sampler) = make()
        delegate.state.transition(to: .open(.timer))
        try pick(delegate)
        sampler.finish(with: Self.blue)

        delegate.state.transition(to: .open(.clipboard))

        #expect(delegate.state.pickedColor == Self.blue)
    }

    /// A swatch re-copies its colour, in the current format, and moves it to
    /// the front.
    @Test func aSwatchCopiesItsColourAgain() throws {
        let (delegate, sampler) = make()
        delegate.state.transition(to: .open(.timer))
        try pick(delegate)
        sampler.finish(with: Self.blue)
        try pick(delegate)
        sampler.finish(with: Self.red)
        #expect(copied(delegate) == "#FF0000")

        try copy(Self.blue, in: delegate)

        #expect(copied(delegate) == "#3A7BD5")
        #expect(delegate.state.recentColors == [Self.blue, Self.red])
        #expect(delegate.state.pickedColor == Self.blue)
    }

    @Test func dismissingTheStripKeepsTheHistory() throws {
        let (delegate, sampler) = make()
        delegate.state.transition(to: .open(.timer))
        try pick(delegate)
        sampler.finish(with: Self.blue)

        delegate.state.dismissColorStrip()

        #expect(delegate.state.pickedColor == nil)
        #expect(delegate.state.recentColors == [Self.blue])
    }

    // MARK: - The format

    /// "Copy as" decides what the next copy writes, is saved, and is what a
    /// relaunch reads back.
    @Test func theChosenFormatIsWhatIsCopiedAndIsSaved() throws {
        let (delegate, sampler) = make()
        try setFormat(.rgb, in: delegate)
        #expect(delegate.state.colorFormat == .rgb)
        #expect(delegate.preferencesStore.colorFormat == .rgb)

        delegate.state.transition(to: .open(.timer))
        try pick(delegate)
        sampler.finish(with: Self.blue)

        #expect(copied(delegate) == "rgb(58, 123, 213)")
    }

    @Test func aSavedFormatIsLoadedAtInstall() {
        let sampler = FakeColorSampler()
        let delegate = AppDelegate()
        delegate.shelfTrash = TestTrash.shelf
        let defaults = TestDefaults.isolated("color-picker")
        PreferencesStore(defaults: defaults).setColorFormat(.swiftUI)
        delegate.preferencesDefaults = defaults
        delegate.growthDelay = .zero
        delegate.colorSampler = sampler
        delegate.install(metrics: NotchedDelegate.metrics)

        #expect(delegate.state.colorFormat == .swiftUI)
        #expect(delegate.colorPicker?.format == .swiftUI)
    }

    // MARK: - The module switch

    /// Off means the dropper does nothing, and the app holds no colours.
    @Test func switchingOffForgetsTheHistoryAndRefusesPicks() throws {
        let (delegate, sampler) = make()
        delegate.state.transition(to: .open(.timer))
        try pick(delegate)
        sampler.finish(with: Self.blue)
        #expect(delegate.state.recentColors == [Self.blue])

        delegate.switchboard.setEnabled(false, for: .colorPicker)

        #expect(delegate.state.recentColors.isEmpty)
        #expect(delegate.state.pickedColor == nil)
        delegate.state.onPickColor?()
        #expect(sampler.requests == 1, "a switched-off picker started the sampler")
    }

    /// The loupe has no cancel API, so a pick that finishes after the switch
    /// went off is dropped rather than copied.
    @Test func aPickFinishingAfterSwitchOffIsDropped() throws {
        let (delegate, sampler) = make()
        delegate.colorPasteboard.clearContents()
        delegate.colorPasteboard.setString("before", forType: .string)
        delegate.state.transition(to: .open(.timer))
        try pick(delegate)

        delegate.switchboard.setEnabled(false, for: .colorPicker)
        sampler.finish(with: Self.blue)

        #expect(copied(delegate) == "before")
        #expect(delegate.state.recentColors.isEmpty)
        #expect(delegate.state.state == .closed, "a dropped pick reopened the panel")
    }

    /// The launch path is the switchboard's `apply()`, like every module.
    @Test func aPickerSwitchedOffBeforeLaunchNeverSamples() {
        let (delegate, sampler) = make()
        delegate.preferencesStore.setEnabled(false, for: .colorPicker)
        delegate.startSubsystems()
        defer { delegate.activity.stop() }

        delegate.state.transition(to: .open(.timer))
        delegate.state.onPickColor?()

        #expect(sampler.requests == 0)
        #expect(delegate.state.preferences.colorPicker == false)
    }

    @Test func switchingBackOnPicksAgain() throws {
        let (delegate, sampler) = make()
        delegate.switchboard.setEnabled(false, for: .colorPicker)
        delegate.switchboard.setEnabled(true, for: .colorPicker)
        delegate.state.transition(to: .open(.timer))
        try pick(delegate)
        #expect(sampler.requests == 1)
    }

    // MARK: - Sandboxing

    /// A bare delegate shows no loupe and writes to no real pasteboard; only
    /// the launch path opts into either.
    @Test func aFreshDelegateSamplesNothingAndCopiesNowhereReal() {
        let delegate = AppDelegate()
        #expect(delegate.colorSampler is InertColorSampler)
        #expect(delegate.colorPasteboard.name != NSPasteboard.general.name)
    }

    @Test func theRealLaunchUsesTheSystemSamplerAndPasteboard() {
        let delegate = AppDelegate()
        delegate.configureForRealLaunch()
        #expect(delegate.colorSampler is SystemColorSampler)
        #expect(delegate.colorPasteboard.name == NSPasteboard.general.name)
    }

    /// The conversion from what `NSColorSampler` hands back: always to sRGB,
    /// whatever space the pixel came in.
    @Test func anNSColorIsReadInSRGB() throws {
        let srgb = try #require(SampledColor(NSColor(srgbRed: 58 / 255, green: 123 / 255, blue: 213 / 255, alpha: 1)))
        #expect(srgb == Self.blue)

        // Display P3 red is outside sRGB; converted, it clamps to sRGB red.
        let p3 = try #require(SampledColor(NSColor(displayP3Red: 1, green: 0, blue: 0, alpha: 1)))
        #expect(p3.red8 == 255)
        #expect(p3.green8 == 0)

        // A pattern colour has no components at all.
        let pattern = NSColor(patternImage: NSImage(size: NSSize(width: 1, height: 1)))
        #expect(SampledColor(pattern) == nil)
    }
}
