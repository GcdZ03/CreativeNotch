import AppKit
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// The adjustable limits from the app's side (2026-10-24): what was saved is
/// what the stores are built with, and a change in Settings is persisted and
/// applied in one call — to the shelf, the clipboard ring, the timer's presets
/// and its chime — with nothing waiting for a relaunch.
@MainActor
struct LimitsWiringTests {

    private static let custom = Limits(
        shelfCapacity: 10, shelfExpiry: .never, clipboardCapacity: 25,
        timerPresets: [2, 15, 45], chime: .submarine
    )

    private func controller(_ d: AppDelegate) -> PreferencesController {
        PreferencesController(switchboard: d.switchboard, state: d.state, launchAtLogin: d.launchAtLogin)
    }

    // MARK: - At install

    @Test func aFreshDomainGivesTheOldNumbers() throws {
        let d = NotchedDelegate.make()
        #expect(d.state.limits == Limits())
        #expect(try #require(d.shelf).capacity == 20)
        #expect(try #require(d.shelf).maxAge == ShelfStore.defaultMaxAge)
        #expect(try #require(d.clipboard).store.capacity == 50)
    }

    /// The stores are built with the saved limits, so the launch purge runs
    /// against the chosen age rather than the default one.
    @Test func theSavedLimitsAreWhatTheStoresAreBuiltWith() throws {
        let defaults = TestDefaults.isolated("limits")
        PreferencesStore(defaults: defaults).saveLimits(Self.custom)

        let d = AppDelegate()
        d.preferencesDefaults = defaults
        d.growthDelay = .zero
        d.shelfDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CreativeNotchLimits-\(UUID().uuidString)")
        d.playChime = { _ in }
        d.install(metrics: NotchedDelegate.metrics)

        #expect(d.state.limits == Self.custom)
        #expect(try #require(d.shelf).capacity == 10)
        #expect(try #require(d.shelf).maxAge == nil)
        #expect(try #require(d.clipboard).store.capacity == 25)
    }

    /// **The launch purge runs against the saved age, not the default.**
    ///
    /// The test above ends with `maxAge == nil` on an empty shelf, so it
    /// still passes if `install` purges at the default seven days and only
    /// then applies the saved limits. A shelf saved as Never or 30 days
    /// holding an 8-day-old file is what that order would lose.
    @Test(arguments: [ShelfExpiry.never, .thirtyDays])
    func theLaunchPurgeKeepsWhatTheSavedExpiryKeeps(_ expiry: ShelfExpiry) throws {
        let defaults = TestDefaults.isolated("limits-purge")
        PreferencesStore(defaults: defaults).saveLimits(Limits(shelfExpiry: expiry))

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CreativeNotchLimits-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let eightDaysAgo = Date().addingTimeInterval(-8 * 24 * 3600)
        let old = try ShelfStore(directory: directory).add(.text("eight days old"), now: eightDaysAgo)

        let d = AppDelegate()
        d.preferencesDefaults = defaults
        d.growthDelay = .zero
        d.shelfDirectory = directory
        d.playChime = { _ in }
        d.announce = { _ in }
        d.install(metrics: NotchedDelegate.metrics)

        let shelf = try #require(d.shelf)
        #expect(shelf.items.map(\.url.lastPathComponent) == [old.url.lastPathComponent])
        #expect(FileManager.default.fileExists(atPath: old.url.path))
    }

    // MARK: - From Settings

    @Test func settingsPersistsAndAppliesInOneCall() {
        let d = NotchedDelegate.make()
        let c = controller(d)

        c.setLimits(Self.custom)

        #expect(d.state.limits == Self.custom)
        #expect(c.limits == Self.custom)
        #expect(d.preferencesStore.loadLimits() == Self.custom)
    }

    @Test func loweringTheShelfCapacityEvictsAtOnce() throws {
        let d = NotchedDelegate.make()
        let shelf = try #require(d.shelf)
        for i in 0..<20 {
            try shelf.add(.text("item \(i)"), now: Date().addingTimeInterval(Double(i)))
        }

        var limits = d.state.limits
        limits.shelfCapacity = 10
        controller(d).setLimits(limits)

        #expect(shelf.capacity == 10)
        #expect(shelf.items.count == 10)
    }

    @Test func shorteningTheExpiryAppliesToTheShelf() throws {
        let d = NotchedDelegate.make()
        var limits = d.state.limits
        limits.shelfExpiry = .oneDay
        controller(d).setLimits(limits)
        #expect(try #require(d.shelf).maxAge == ShelfExpiry.oneDay.maxAge)
    }

    @Test func shrinkingTheClipboardTrimsAtOnce() throws {
        let d = NotchedDelegate.make()
        let store = try #require(d.clipboard).store
        for i in 0..<50 {
            store.record(.text("entry \(i)"), now: Date().addingTimeInterval(Double(i)))
        }

        var limits = d.state.limits
        limits.clipboardCapacity = 25
        controller(d).setLimits(limits)

        #expect(store.capacity == 25)
        #expect(store.entries.count == 25)
    }

    /// The tab reads its presets from `AppState`, which is what the setter
    /// updates — so the next time the tab draws, it draws the new ones.
    @Test func newPresetsReachTheTimerTab() {
        let d = NotchedDelegate.make()
        var limits = d.state.limits
        limits.timerPresets = [1, 2, 3]
        controller(d).setLimits(limits)
        #expect(d.state.limits.timerPresets == [1, 2, 3])
        #expect(NotchRootView.timerPresets(d.state) == [1, 2, 3])
    }

    // MARK: - The chime

    @Test func finishingPlaysTheChosenChime() throws {
        let d = NotchedDelegate.make()
        var played: [ChimeSound] = []
        d.playChime = { played.append($0) }
        var limits = d.state.limits
        limits.chime = .ping
        d.state.onSetLimits?(limits)
        played.removeAll()   // the preview

        d.timerDidFinish(try #require(
            Countdown(duration: 60, startingAt: Date().addingTimeInterval(-60))
        ))

        #expect(played == [.ping])
    }

    /// Choosing a chime plays it once, so the menu can be auditioned without
    /// running a timer to the end.
    @Test func choosingAChimePreviewsIt() {
        let d = NotchedDelegate.make()
        var played: [ChimeSound] = []
        d.playChime = { played.append($0) }

        var limits = d.state.limits
        limits.chime = .hero
        controller(d).setLimits(limits)

        #expect(played == [.hero])
    }

    /// Only the chime previews: moving the clipboard size must not make a
    /// sound, nor must choosing silence.
    @Test func otherChangesAndNoneDoNotPreview() {
        let d = NotchedDelegate.make()
        var played: [ChimeSound] = []
        d.playChime = { played.append($0) }
        let c = controller(d)

        var limits = d.state.limits
        limits.clipboardCapacity = 100
        c.setLimits(limits)
        limits.chime = .none
        c.setLimits(limits)

        #expect(played.isEmpty)
    }

    // MARK: - The Settings rows

    /// The rows sit under the module they limit, so the shelf, the clipboard
    /// and the timer each offer theirs and nothing else does.
    @Test func theLimitedModulesAreTheOnesWithLimitRows() {
        let limited = ModuleID.allCases.filter(PreferencesView.hasLimits)
        #expect(Set(limited) == [.shelf, .clipboard, .timer])
    }

    /// The binding the rows are built from, both directions — a getter
    /// reading the wrong field or a setter that applies without persisting
    /// is invisible to every other kind of test.
    @Test func aLimitBindingReadsAndWritesThroughTheController() {
        let d = NotchedDelegate.make()
        let c = controller(d)
        let capacity = LimitsRows.binding(\.clipboardCapacity, on: c)

        #expect(capacity.wrappedValue == 50)
        capacity.wrappedValue = 100

        #expect(d.state.limits.clipboardCapacity == 100)
        #expect(d.preferencesStore.loadLimits().clipboardCapacity == 100)
    }

    /// A typed preset out of range is clamped to what a countdown accepts
    /// before it is stored.
    @Test func aTypedPresetIsClamped() {
        let d = NotchedDelegate.make()
        let preset = LimitsRows.binding(\.timerPresets[2], on: controller(d))

        preset.wrappedValue = 500

        #expect(d.state.limits.timerPresets == [5, 10, TimerStepper.maximum])
        #expect(preset.wrappedValue == TimerStepper.maximum)
    }
}
