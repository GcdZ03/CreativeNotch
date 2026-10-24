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
        d.shelfTrash = TestTrash.shelf
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
        let old = try ShelfStore(directory: directory, trash: TestTrash.shelf).add(.text("eight days old"), now: eightDaysAgo)

        let d = AppDelegate()
        d.shelfTrash = TestTrash.shelf
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

    /// Once confirmed, a lowered capacity evicts at once — through a
    /// sandboxed Trash, so the ten evicted files never reach the real one.
    @Test func loweringTheShelfCapacityEvictsAtOnceWhenConfirmed() throws {
        let trash = SandboxTrash()
        let d = NotchedDelegate.make(shelfTrash: trash.shelf)
        let shelf = try #require(d.shelf)
        try fill(shelf, count: 20)
        let c = controller(d)

        var limits = d.state.limits
        limits.shelfCapacity = 10
        c.setLimits(limits)
        c.confirmLimits(try #require(c.pendingLimits.change))

        #expect(shelf.capacity == 10)
        #expect(shelf.items.count == 10)
        #expect(trash.trashed.count == 10)
        #expect(d.preferencesStore.loadLimits().shelfCapacity == 10)
        #expect(c.pendingLimits.change == nil)
    }

    // MARK: - Asking before a limit trashes files

    /// **A change that would trash files is held, not applied.** Nothing
    /// moves, nothing is saved, and Settings is handed what to ask.
    @Test func aRemovingChangeIsHeldUntilConfirmed() throws {
        let trash = SandboxTrash()
        let d = NotchedDelegate.make(shelfTrash: trash.shelf)
        let shelf = try #require(d.shelf)
        try fill(shelf, count: 20)
        let before = shelf.items
        let c = controller(d)

        var limits = d.state.limits
        limits.shelfCapacity = 10
        c.setLimits(limits)

        let held = try #require(c.pendingLimits.change)
        #expect(held.limits.shelfCapacity == 10)
        #expect(held.removal.count == 10)
        #expect(shelf.items == before)
        #expect(shelf.capacity == 20)
        #expect(trash.trashed.isEmpty)
        #expect(d.state.limits.shelfCapacity == 20)
        #expect(d.preferencesStore.loadLimits().shelfCapacity == 20)
    }

    /// **Cancel changes nothing**, and the picker goes back: while the
    /// question is up it shows the choice being asked about, and after Cancel
    /// the value it was.
    @Test func cancelLeavesTheStoreAndThePreferenceUntouched() throws {
        let trash = SandboxTrash()
        let d = NotchedDelegate.make(shelfTrash: trash.shelf)
        let shelf = try #require(d.shelf)
        try fill(shelf, count: 20)
        let before = shelf.items
        let c = controller(d)
        let capacity = LimitsRows.binding(\.shelfCapacity, on: c)

        capacity.wrappedValue = 10
        #expect(capacity.wrappedValue == 10, "the picker should show what it is asking about")
        c.cancelLimits()

        #expect(c.pendingLimits.change == nil)
        #expect(capacity.wrappedValue == 20)
        #expect(shelf.items == before)
        #expect(shelf.capacity == 20)
        #expect(trash.trashed.isEmpty)
        #expect(d.state.limits == Limits())
        #expect(d.preferencesStore.loadLimits() == Limits())
    }

    /// The expiry is held the same way: a two-day-old file under a new
    /// one-day limit is asked about first.
    @Test func shorteningTheExpiryPastAFileIsHeld() throws {
        let trash = SandboxTrash()
        let d = NotchedDelegate.make(shelfTrash: trash.shelf)
        let shelf = try #require(d.shelf)
        let old = try shelf.add(.text("two days old"), now: Date().addingTimeInterval(-2 * 24 * 3600))
        let c = controller(d)

        var limits = d.state.limits
        limits.shelfExpiry = .oneDay
        c.setLimits(limits)

        #expect(c.pendingLimits.change?.removal.items.map(\.id) == [old.id])
        #expect(shelf.maxAge == ShelfStore.defaultMaxAge)
        #expect(FileManager.default.fileExists(atPath: old.url.path))

        c.confirmLimits(try #require(c.pendingLimits.change))
        #expect(shelf.items.isEmpty)
        #expect(trash.trashed.count == 1)
        #expect(d.state.limits.shelfExpiry == .oneDay)
    }

    /// **A change that takes nothing applies directly**, as before: the
    /// question is for the cases that would trash something, or it becomes
    /// a click everyone learns to make without reading.
    @Test func aNonRemovingChangeAppliesDirectly() throws {
        let trash = SandboxTrash()
        let d = NotchedDelegate.make(shelfTrash: trash.shelf)
        let shelf = try #require(d.shelf)
        try fill(shelf, count: 3)
        let c = controller(d)

        var limits = d.state.limits
        limits.shelfCapacity = 10
        limits.shelfExpiry = .oneDay
        c.setLimits(limits)

        #expect(c.pendingLimits.change == nil)
        #expect(shelf.capacity == 10)
        #expect(shelf.maxAge == ShelfExpiry.oneDay.maxAge)
        #expect(shelf.items.count == 3)
        #expect(d.preferencesStore.loadLimits() == limits)
    }

    /// The dialog's presentation binding: up while a change is held, and
    /// dismissing it (Escape, a click outside) is a Cancel, never a confirm.
    @Test func dismissingTheDialogCancels() throws {
        let trash = SandboxTrash()
        let d = NotchedDelegate.make(shelfTrash: trash.shelf)
        let shelf = try #require(d.shelf)
        try fill(shelf, count: 20)
        let c = controller(d)
        let presented = LimitsRows.confirming(c)
        #expect(presented.wrappedValue == false)

        LimitsRows.binding(\.shelfCapacity, on: c).wrappedValue = 10
        #expect(presented.wrappedValue == true)

        presented.wrappedValue = false
        #expect(c.pendingLimits.change == nil)
        #expect(shelf.items.count == 20)
        #expect(trash.trashed.isEmpty)
        #expect(d.state.limits.shelfCapacity == 20)
    }

    /// Confirm applies what the dialog showed even when SwiftUI has already
    /// dismissed it — and so dropped the hold — before the button's action.
    @Test func confirmingAfterTheDismissalStillApplies() throws {
        let trash = SandboxTrash()
        let d = NotchedDelegate.make(shelfTrash: trash.shelf)
        let shelf = try #require(d.shelf)
        try fill(shelf, count: 20)
        let c = controller(d)

        LimitsRows.binding(\.shelfCapacity, on: c).wrappedValue = 10
        let shown = try #require(c.pendingLimits.change)
        LimitsRows.confirming(c).wrappedValue = false
        c.confirmLimits(shown)

        #expect(shelf.items.count == 10)
        #expect(d.preferencesStore.loadLimits().shelfCapacity == 10)
    }

    /// **An item the current limits already condemn asks nothing.** The
    /// purge runs only at launch and after an add, so a file can be past the
    /// expiry and still listed. A clipboard change, or a raised shelf limit,
    /// must apply without a shelf question -- with the shelf row hidden there
    /// would be no dialog to answer it, and the change would be held forever.
    @Test func anAlreadyExpiredItemDoesNotHoldAnUnrelatedChange() throws {
        let trash = SandboxTrash()
        let d = NotchedDelegate.make(shelfTrash: trash.shelf)
        let shelf = try #require(d.shelf)
        // Added "nine days ago" and purged at that time, so still listed.
        try shelf.add(.text("nine days old"), now: Date().addingTimeInterval(-9 * 24 * 3600))
        #expect(shelf.items.count == 1)
        let c = controller(d)

        var limits = d.state.limits
        limits.clipboardCapacity = 25
        c.setLimits(limits)
        #expect(c.pendingLimits.change == nil)
        #expect(d.state.limits.clipboardCapacity == 25)
        #expect(shelf.items.count == 1, "the clipboard's change does not touch the shelf")

        limits.shelfCapacity = 50
        c.setLimits(limits)
        #expect(c.pendingLimits.change == nil)
        #expect(d.state.limits.shelfCapacity == 50)
    }

    /// The same for a file that refuses the Trash: it stays listed past the
    /// expiry, and must not bring the question back on every change.
    @Test func aStuckExpiredFileDoesNotAskAgain() throws {
        let trash = SandboxTrash()
        let d = NotchedDelegate.make(shelfTrash: trash.shelf)
        let shelf = try #require(d.shelf)
        let stuck = try shelf.add(.text("two days old"), now: Date().addingTimeInterval(-2 * 24 * 3600))
        trash.refuse(stuck.url)
        let c = controller(d)

        var limits = d.state.limits
        limits.shelfExpiry = .oneDay
        c.setLimits(limits)
        c.confirmLimits(try #require(c.pendingLimits.change))
        #expect(shelf.items.map(\.id) == [stuck.id])

        limits.shelfCapacity = 10
        c.setLimits(limits)
        #expect(c.pendingLimits.change == nil)
        #expect(d.state.limits.shelfCapacity == 10)
    }

    /// **Confirm never takes more than the dialog counted.** Files dropped
    /// while the question is up change what the lowered capacity evicts; the
    /// change is asked about again with the new count, and nothing moves
    /// until that is confirmed.
    @Test func confirmingAfterTheShelfChangedAsksAgain() throws {
        let trash = SandboxTrash()
        let d = NotchedDelegate.make(shelfTrash: trash.shelf)
        let shelf = try #require(d.shelf)
        try fill(shelf, count: 20)
        let c = controller(d)
        let presented = LimitsRows.confirming(c)

        LimitsRows.binding(\.shelfCapacity, on: c).wrappedValue = 10
        let shown = try #require(c.pendingLimits.change)
        #expect(presented.wrappedValue)
        #expect(shown.removal.count == 10)

        // Three drops while the dialog is open; the full shelf evicts its
        // own three oldest, which is the add's rule, not the change's.
        for i in 0..<3 {
            try shelf.add(.text("late \(i)"), now: Date().addingTimeInterval(100 + Double(i)))
        }
        let trashedBefore = trash.trashed.count
        let listedBefore = shelf.items

        c.confirmLimits(shown)

        let asked = try #require(c.pendingLimits.change, "the grown removal should be asked about")
        #expect(asked.removal != shown.removal)
        #expect(shelf.items == listedBefore)
        #expect(trash.trashed.count == trashedBefore)
        #expect(d.state.limits.shelfCapacity == 20)

        // SwiftUI reporting the old dialog's dismissal after the action must
        // not drop the new question.
        presented.wrappedValue = false
        #expect(c.pendingLimits.change == asked)

        c.confirmLimits(asked)
        #expect(c.pendingLimits.change == nil)
        #expect(shelf.items.count == 10)
        #expect(trash.trashed.count == trashedBefore + asked.removal.trashedCount)
    }

    private func fill(_ shelf: ShelfStore, count: Int) throws {
        for i in 0..<count {
            try shelf.add(.text("item \(i)"), now: Date().addingTimeInterval(Double(i)))
        }
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
