# Clipboard History Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A 50-entry, in-memory clipboard history in the notch — the app's only genuine poller, and the module with the most direct access to secrets, so it is the most tightly constrained one in the project.

**Architecture:** `NSPasteboard` has no change notification, so this module polls. Everything that decides *when* to poll and *what to keep* is pure logic in `CreativeNotchCore` and runs headlessly: the interval schedule, the ring, the size caps, and the sleep/lock reducer. `CreativeNotchUI` holds only the parts that must touch AppKit — reading the pasteboard, receiving workspace notifications, and owning the timer. The timer is injected the way `AppDelegate.installOutsideClickMonitor` is, so the whole poll path is tested by calling `tick(now:)` directly rather than by sleeping.

**Tech Stack:** Swift 6.3, SwiftUI, AppKit, Observation, Swift Testing, SwiftPM. No third-party dependencies.

**Spec:** `docs/specs/2026-08-22-creativenotch-design.md` — sections 4.7 (`SystemActivity`), 5.3 (Clipboard), 6 (Permissions).

This plan also discharges the `SystemActivity` deferral recorded in `docs/plans/2026-08-22-foundation.md` ("Deliberately does not build"), which named the clipboard poller as its first and most important consumer.

## Global Constraints

- Minimum platform **macOS 26.0**.
- **No third-party dependencies.**
- **`CreativeNotchCore` must never `import AppKit`, `import SwiftUI`, `import UIKit` or `import Cocoa`.** `CorePurityTests` enforces this mechanically, recursively, and sees through attributed imports such as `@preconcurrency import AppKit`. `import Observation` and `import Foundation` are permitted.
- **No polling — except here.** This module is the spec's single admitted exception. The exception covers **one** repeating timer, owned by `ClipboardPoller`, suspended outside `.active`. No second timer, and no mouse or event monitors, may be added by this plan.
- **`FileManager.removeItem` remains banned** in the shelf module. This module touches no files at all: nothing it captures is ever written to disk.
- **Never log captured content.** No `NSLog`, `print`, or `debugPrint` may take a `ClipboardContent`, its associated `String`, or its `Data` as an argument. A crash log containing a password is the exact failure this module exists to avoid.
- **Never mutate `AppState.state` directly.** It is `private(set)`; go through `transition(to:)`. Register observers with `observe`, never replace them.
- `now` is passed as a parameter, never read from a clock inside pure logic.
- All new types in `CreativeNotchCore` are `public`, `Equatable`, and `Sendable`.
- **No `Task.sleep` in tests.** Seven tests once failed on CI while passing locally because they slept past a delay. `ClipboardPoller` exposes `tick(now:)` and an injectable timer for exactly this reason.
- **Tests must never touch the machine's real clipboard.** Always construct `NSPasteboard(name:)` with a per-test UUID, as `PasteboardDropTests` does. `NSPasteboard.general` must not appear in any test file.
- **Every new test must be proven to fail against the bug it targets** — introduce the bug, watch it fail, revert. Verify the build succeeds before interpreting a mutation result: an invalid mutation breaks the build, produces no test failures, and looks identical to an uncaught bug.
- Conventional commit prefixes (`feat:`, `fix:`, `test:`, `chore:`, `docs:`).
- Baseline before this plan: **221 tests in 26 suites, all passing.** Every task must leave the suite green.

## File Structure

**`CreativeNotchCore` — pure, headless, CI-testable**

| File | Responsibility |
|---|---|
| `SystemActivity.swift` | The `.active` / `.locked` / `.asleep` enum and the pure reducer that folds workspace events into it |
| `Clipboard/ClipboardContent.swift` | What a captured item *is* — text or image — and its byte cost |
| `Clipboard/ClipboardLimits.swift` | The size caps, and the single `accepts(_:)` predicate both the reader and the store apply |
| `Clipboard/ClipboardEntry.swift` | One ring slot: identity, content, timestamp |
| `Clipboard/ClipboardStore.swift` | The 50-entry ring — promotion, eviction, clearing |
| `Clipboard/ClipboardPollSchedule.swift` | Pure interval maths: active rate, idle back-off, Low Power floor |

**`CreativeNotchUI` — AppKit at the edges**

| File | Responsibility |
|---|---|
| `SystemActivityObserver.swift` | Workspace and distributed notifications → `SystemActivityEvent` → reducer |
| `Clipboard/Pasteboard+Clipboard.swift` | One `NSPasteboard` read, with the skip-type filter |
| `Clipboard/ClipboardPoller.swift` | Owns the timer and the `changeCount` baseline; decides when to read |
| `Clipboard/ClipboardController.swift` | Poller → store wiring and the activity gate, mirroring `HUDController` |
| `Clipboard/ClipboardView.swift` | The list, its thumbnails, and click-to-copy-back |
| `PanelTabBar.swift` | The shelf / clipboard switcher inside the open panel |

**Modified:** `ShelfStore.swift` (`@Observable`, Task 0), `NotchRootView.swift` (clipboard case, tab bar, last-tab memory), `MenuBarController.swift` (clear item), `AppDelegate.swift` (lifecycle wiring), `CorePurityTests.swift` (recursion anchors), `MenuBarShelfTests.swift` (new init arguments), `README.md`.

Task 0 is a prerequisite bug fix rather than part of the module. It is first, and in its own commit, for the reasons given there.

---

### Task 0: Make `ShelfStore` observable — a prerequisite bug fix

**Not part of the clipboard module.** It lands here, first and in its own
commit, because this plan adds a second store whose view has the same
requirement, and shipping the fix for one while leaving the identical bug
in the other is not defensible.

**The bug.** `AppState` is the only `@Observable` type in the project.
`ShelfStore` is a plain `@MainActor final class`, and `ShelfView` holds
`let store: ShelfStore` and reads `store.items` in its body — so SwiftUI
has no signal when `items` changes.

It looks like it works because the drop handler ends with
`state.transition(to: .open(.shelf))`, and *that* invalidates
`NotchRootView`, which rebuilds `ShelfView` from scratch. The view is
refreshed by the state change, not by the store.

The path with no state change is `AppDelegate.swift:152`:

```swift
onClearShelf: { [weak self] in try? self?.shelf?.clear() },
```

Open the panel on the shelf, clear it from the menu bar, and the files go
to the Trash while their thumbnails stay on screen.

The comment on `AppState.shelf` asserts the store "publishes its own
changes". Today it does not. This makes the comment true rather than
deleting it.

**Files:**
- Modify: `Sources/CreativeNotchCore/Shelf/ShelfStore.swift`
- Modify: `Sources/CreativeNotchUI/NotchRootView.swift` (the inaccurate comment)
- Create: `Tests/CreativeNotchCoreTests/ShelfStoreObservationTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: no API change. `ShelfStore` gains `@Observable`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/CreativeNotchCoreTests/ShelfStoreObservationTests.swift`:

```swift
import Foundation
import Observation
import Testing
@testable import CreativeNotchCore

/// `ShelfView` reads `store.items` in its body and holds the store as a
/// plain `let`. Without `@Observable` on the store, SwiftUI has no way to
/// learn that `items` changed.
///
/// The bug that hides this: every *drop* is followed by
/// `state.transition(to: .open(.shelf))`, and `AppState` is observable —
/// so the view is rebuilt by the state change and appears to track the
/// store. The menu bar's "Clear Shelf" performs no transition, so an open
/// shelf keeps showing items whose files are already in the Trash.
///
/// `withObservationTracking` is the same mechanism SwiftUI uses, so this
/// tests the real question rather than a proxy for it.
@MainActor
struct ShelfStoreObservationTests {

    private func makeStore() throws -> ShelfStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CreativeNotchShelfObs-\(UUID().uuidString)")
        return try ShelfStore(directory: directory)
    }

    @Test func addingAnItemNotifiesObservers() throws {
        let store = try makeStore()
        var notified = false

        withObservationTracking {
            _ = store.items
        } onChange: {
            notified = true
        }

        try store.add(.text("hello"), now: Date())

        #expect(notified, "a shelf view reading items must be told when one is added")
    }

    /// The path with no accompanying state transition — the one that is
    /// visibly broken today.
    @Test func clearingNotifiesObservers() throws {
        let store = try makeStore()
        try store.add(.text("hello"), now: Date())

        var notified = false
        withObservationTracking {
            _ = store.items
        } onChange: {
            notified = true
        }

        try store.clear()

        #expect(notified, "clearing from the menu bar must refresh an open shelf")
    }

    @Test func removingAnItemNotifiesObservers() throws {
        let store = try makeStore()
        let item = try store.add(.text("hello"), now: Date())

        var notified = false
        withObservationTracking {
            _ = store.items
        } onChange: {
            notified = true
        }

        try store.remove(item.id)

        #expect(notified)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter ShelfStoreObservationTests`
Expected: FAIL — all three, because `withObservationTracking` never fires for a non-observable type.

This failure is the bug report. Confirm all three fail before changing anything.

- [ ] **Step 3: Make the store observable**

In `Sources/CreativeNotchCore/Shelf/ShelfStore.swift`, add the import and the macro:

```swift
import Foundation
import Observation
```

```swift
/// `@Observable` so a view reading `items` is told when they change.
/// Without it the shelf appeared to work only because every drop is
/// followed by a state transition that rebuilt the view anyway — and
/// "Clear Shelf" from the menu bar, which performs no transition, left
/// thumbnails on screen for files already in the Trash.
@MainActor
@Observable
public final class ShelfStore {
```

`Observation` is not a UI framework, so `CorePurityTests` is unaffected.

- [ ] **Step 4: Correct the comment in `AppState`**

In `Sources/CreativeNotchUI/NotchRootView.swift`, the `shelf` property's comment currently claims the store publishes its own changes, which only became true in the previous step. Tidy the doubled-up comment left there:

```swift
    /// Set once at install. `@ObservationIgnored` because the store
    /// publishes its own changes — it is `@Observable`, so the view
    /// redraws from the store rather than from this reference, and
    /// re-assigning it must not invalidate a view.
    @ObservationIgnored
    public var shelf: ShelfStore?
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter ShelfStoreObservationTests`
Expected: PASS, 3 tests.

- [ ] **Step 6: Run the full suite**

Run: `swift test`
Expected: PASS, 224 tests. No existing test should change behaviour — `@Observable` adds notification, it does not alter `items`.

- [ ] **Step 7: Commit**

```bash
git add Sources/CreativeNotchCore/Shelf/ShelfStore.swift Sources/CreativeNotchUI/NotchRootView.swift Tests/CreativeNotchCoreTests/ShelfStoreObservationTests.swift
git commit -m "fix: make ShelfStore observable so an open shelf redraws"
```

---

### Task 1: `SystemActivity` — the gate every poller answers to

Spec section 4.7. Deferred out of the foundation plan because nothing polled yet; the clipboard poller is its first consumer, so it lands here.

The subtlety this task exists for: **sleeping and locking are independent, and they overlap.** macOS locks the screen *on wake* from sleep, so the event order is `willSleep`, `screenLocked`, `didWake`, `screenUnlocked`. A reducer that stores one flat state and sets `.active` on `didWake` would resume polling while the lock screen is still up. Two independent booleans with a fixed precedence are what make that impossible.

**Files:**
- Create: `Sources/CreativeNotchCore/SystemActivity.swift`
- Create: `Tests/CreativeNotchCoreTests/SystemActivityTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `enum SystemActivity: String, CaseIterable, Equatable, Sendable { case active, locked, asleep }`
  - `enum SystemActivityEvent: Equatable, Sendable { case willSleep, didWake, screenLocked, screenUnlocked }`
  - `struct SystemActivityReducer: Equatable, Sendable` with `init()`, `var activity: SystemActivity { get }`, and `@discardableResult mutating func apply(_ event: SystemActivityEvent) -> SystemActivity`

- [ ] **Step 1: Write the failing tests**

Create `Tests/CreativeNotchCoreTests/SystemActivityTests.swift`:

```swift
import Foundation
import Testing
@testable import CreativeNotchCore

/// Spec section 4.7: "No poller may run outside `.active`. Enforced once,
/// here."
///
/// Sleeping and locking are independent conditions that overlap in normal
/// use — macOS locks the screen *on wake*, so a machine coming back from
/// sleep passes through a state that is both. Collapsing them into one
/// flat value makes `didWake` look like "everything is fine again", which
/// would resume polling with the lock screen still on top of it.
struct SystemActivityTests {

    @Test func aFreshMachineIsActive() {
        #expect(SystemActivityReducer().activity == .active)
    }

    @Test func lockingLeavesActive() {
        var reducer = SystemActivityReducer()
        #expect(reducer.apply(.screenLocked) == .locked)
    }

    @Test func unlockingRestoresActive() {
        var reducer = SystemActivityReducer()
        reducer.apply(.screenLocked)
        #expect(reducer.apply(.screenUnlocked) == .active)
    }

    @Test func sleepingLeavesActive() {
        var reducer = SystemActivityReducer()
        #expect(reducer.apply(.willSleep) == .asleep)
    }

    @Test func wakingRestoresActive() {
        var reducer = SystemActivityReducer()
        reducer.apply(.willSleep)
        #expect(reducer.apply(.didWake) == .active)
    }

    /// The real sequence a closed lid produces. `didWake` arrives while
    /// the lock screen is still up, and must not read as "resume".
    @Test func wakingWhileStillLockedStaysLocked() {
        var reducer = SystemActivityReducer()
        reducer.apply(.willSleep)
        reducer.apply(.screenLocked)
        #expect(reducer.apply(.didWake) == .locked)
        #expect(reducer.apply(.screenUnlocked) == .active)
    }

    /// Sleep outranks lock: a locked machine that then sleeps is asleep,
    /// and unlocking underneath that does not wake it.
    @Test func sleepOutranksLock() {
        var reducer = SystemActivityReducer()
        reducer.apply(.screenLocked)
        #expect(reducer.apply(.willSleep) == .asleep)
        #expect(reducer.apply(.screenUnlocked) == .asleep)
        #expect(reducer.apply(.didWake) == .active)
    }

    /// Notification delivery is not guaranteed to be balanced — a missed
    /// `screenUnlocked` must not leave a permanently suspended poller that
    /// only a relaunch fixes, so the flags are set, never counted.
    @Test func repeatedEventsDoNotStack() {
        var reducer = SystemActivityReducer()
        reducer.apply(.screenLocked)
        reducer.apply(.screenLocked)
        #expect(reducer.apply(.screenUnlocked) == .active)
    }

    @Test func anUnmatchedResumeIsHarmless() {
        var reducer = SystemActivityReducer()
        #expect(reducer.apply(.screenUnlocked) == .active)
        #expect(reducer.apply(.didWake) == .active)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter SystemActivityTests`
Expected: FAIL — `cannot find 'SystemActivityReducer' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/CreativeNotchCore/SystemActivity.swift`:

```swift
import Foundation

/// What the machine is doing, as far as anything that wants to run on a
/// timer is concerned.
///
/// There is deliberately no `.idle` case. Detecting user idle means polling
/// `CGEventSource`, which would violate the very rule this enum exists to
/// serve. Idle back-off lives in `ClipboardPollSchedule` instead, which
/// already knows how long it has been since anything changed.
public enum SystemActivity: String, CaseIterable, Equatable, Sendable {
    case active, locked, asleep
}

/// The notifications this is folded from, named in the app's own terms so
/// `CreativeNotchCore` never has to know an `NSWorkspace` constant.
public enum SystemActivityEvent: Equatable, Sendable {
    case willSleep, didWake, screenLocked, screenUnlocked
}

/// Folds those events into a single activity.
///
/// Two independent booleans rather than one state, because sleeping and
/// locking overlap: macOS locks the screen on wake, so `didWake` arrives
/// while the lock screen is still up. A flat state would treat that wake as
/// a return to `.active` and resume polling behind the lock screen.
///
/// The flags are *set*, never counted. Distributed notifications are not
/// guaranteed to be delivered, and a missed `screenUnlocked` under a
/// counting scheme would leave the poller suspended until relaunch.
public struct SystemActivityReducer: Equatable, Sendable {

    private var isAsleep = false
    private var isLocked = false

    public init() {}

    /// Sleep outranks lock, which outranks active. A sleeping machine is
    /// asleep whether or not it is also locked, and it is the stronger
    /// suspension of the two.
    public var activity: SystemActivity {
        if isAsleep { return .asleep }
        if isLocked { return .locked }
        return .active
    }

    @discardableResult
    public mutating func apply(_ event: SystemActivityEvent) -> SystemActivity {
        switch event {
        case .willSleep:       isAsleep = true
        case .didWake:         isAsleep = false
        case .screenLocked:    isLocked = true
        case .screenUnlocked:  isLocked = false
        }
        return activity
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter SystemActivityTests`
Expected: PASS, 9 tests.

- [ ] **Step 5: Prove the tests bite**

Change `activity` to check `isLocked` before `isAsleep`. Build, then run `swift test --filter SystemActivityTests`. Expected: `sleepOutranksLock` fails. Revert.

Then change `case .didWake: isAsleep = false` to also set `isLocked = false`. Build, run again. Expected: `wakingWhileStillLockedStaysLocked` fails. Revert.

- [ ] **Step 6: Run the full suite**

Run: `swift test`
Expected: PASS, 233 tests.

- [ ] **Step 7: Commit**

```bash
git add Sources/CreativeNotchCore/SystemActivity.swift Tests/CreativeNotchCoreTests/SystemActivityTests.swift
git commit -m "feat: add SystemActivity, the gate that suspends pollers"
```

---

### Task 2: `ClipboardContent` and `ClipboardLimits` — what is worth keeping

The ring holds text and images. File URLs are deliberately excluded: the shelf already handles files, and it handles them by *copying*, because a URL reference goes stale the moment the original moves.

The caps exist because the ring is fifty entries held in RAM for the life of the process. Over-cap content is **skipped, never truncated** — a half-written string pastes back as corrupt data, which is worse than an absent entry.

`accepts(_:)` is one shared predicate with two call sites: the pasteboard reader applies it to avoid materialising an image it would only throw away, and the store applies it as the invariant guard on the ring itself.

**Files:**
- Create: `Sources/CreativeNotchCore/Clipboard/ClipboardContent.swift`
- Create: `Sources/CreativeNotchCore/Clipboard/ClipboardLimits.swift`
- Create: `Tests/CreativeNotchCoreTests/ClipboardContentTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `enum ClipboardContent: Equatable, Hashable, Sendable { case text(String); case image(Data, ext: String) }`
  - `ClipboardContent.byteCount: Int`
  - `ClipboardContent.isBlank: Bool`
  - `enum ClipboardLimits` with `static let maxTextBytes = 1_000_000`, `static let maxImageBytes = 10_000_000`, `static func accepts(_ content: ClipboardContent) -> Bool`, `static func acceptsText(byteCount: Int) -> Bool`, `static func acceptsImage(byteCount: Int) -> Bool`

- [ ] **Step 1: Write the failing tests**

Create `Tests/CreativeNotchCoreTests/ClipboardContentTests.swift`:

```swift
import Foundation
import Testing
@testable import CreativeNotchCore

/// Spec section 5.3. The caps are the whole reason this type carries a
/// byte count: fifty entries live in RAM for the life of the process, so
/// an uncapped entry is an uncapped process.
struct ClipboardContentTests {

    // MARK: - Byte accounting

    /// UTF-8, not `count`. A string of emoji is four bytes per character
    /// and `count` would under-report it by a factor of four — which is
    /// the difference between a 1 MB cap and a 4 MB one.
    @Test func textIsMeasuredInUTF8Bytes() {
        #expect(ClipboardContent.text("abc").byteCount == 3)
        #expect(ClipboardContent.text("🎛️").byteCount == "🎛️".utf8.count)
        #expect(ClipboardContent.text("🎛️").byteCount > "🎛️".count)
    }

    @Test func imagesAreMeasuredByTheirData() {
        let data = Data(repeating: 0, count: 4096)
        #expect(ClipboardContent.image(data, ext: "png").byteCount == 4096)
    }

    @Test func emptyContentCostsNothing() {
        #expect(ClipboardContent.text("").byteCount == 0)
        #expect(ClipboardContent.image(Data(), ext: "png").byteCount == 0)
    }

    // MARK: - Blankness

    /// Whitespace-only text is what a stray select-and-copy produces. The
    /// shelf already refuses it (`Pasteboard+Drop`); the ring does too, so
    /// a fifty-slot history cannot fill with blank lines.
    @Test func whitespaceOnlyTextIsBlank() {
        #expect(ClipboardContent.text("").isBlank)
        #expect(ClipboardContent.text("   \n\t ").isBlank)
        #expect(ClipboardContent.text(" x ").isBlank == false)
    }

    @Test func anImageIsBlankOnlyWhenItHasNoBytes() {
        #expect(ClipboardContent.image(Data(), ext: "png").isBlank)
        #expect(ClipboardContent.image(Data([0x89]), ext: "png").isBlank == false)
    }

    // MARK: - Limits

    @Test func theCapsAreWhatTheSpecSays() {
        #expect(ClipboardLimits.maxTextBytes == 1_000_000)
        #expect(ClipboardLimits.maxImageBytes == 10_000_000)
    }

    /// Exactly at the cap is accepted; one byte over is not. Without this
    /// pair, `<` and `<=` are indistinguishable.
    @Test func theTextBoundaryIsInclusive() {
        #expect(ClipboardLimits.acceptsText(byteCount: ClipboardLimits.maxTextBytes))
        #expect(ClipboardLimits.acceptsText(byteCount: ClipboardLimits.maxTextBytes + 1) == false)
    }

    @Test func theImageBoundaryIsInclusive() {
        #expect(ClipboardLimits.acceptsImage(byteCount: ClipboardLimits.maxImageBytes))
        #expect(ClipboardLimits.acceptsImage(byteCount: ClipboardLimits.maxImageBytes + 1) == false)
    }

    /// The caps differ by an order of magnitude, so applying the wrong one
    /// to the wrong kind is a real mistake with no compiler help. A 5 MB
    /// image is fine; 5 MB of text is not.
    @Test func eachKindGetsItsOwnCap() {
        let fiveMB = 5_000_000
        #expect(ClipboardLimits.accepts(.image(Data(repeating: 0, count: fiveMB), ext: "png")))
        #expect(ClipboardLimits.accepts(.text(String(repeating: "a", count: fiveMB))) == false)
    }

    @Test func blankContentIsNeverAccepted() {
        #expect(ClipboardLimits.accepts(.text("  ")) == false)
        #expect(ClipboardLimits.accepts(.image(Data(), ext: "png")) == false)
    }

    @Test func ordinaryContentIsAccepted() {
        #expect(ClipboardLimits.accepts(.text("hello there")))
        #expect(ClipboardLimits.accepts(.image(Data(repeating: 7, count: 1024), ext: "png")))
    }

    // MARK: - Equality

    /// Promotion in `ClipboardStore` is driven by content equality, so
    /// this is load-bearing rather than incidental.
    @Test func identicalContentComparesEqual() {
        #expect(ClipboardContent.text("a") == ClipboardContent.text("a"))
        #expect(ClipboardContent.text("a") != ClipboardContent.text("b"))

        let data = Data([1, 2, 3])
        #expect(ClipboardContent.image(data, ext: "png") == .image(data, ext: "png"))
        #expect(ClipboardContent.image(data, ext: "png") != .image(data, ext: "tiff"))
        #expect(ClipboardContent.image(data, ext: "png") != .image(Data([1, 2]), ext: "png"))
    }

    @Test func textAndImagesAreNeverEqual() {
        #expect(ClipboardContent.text("x") != .image(Data([1]), ext: "png"))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter ClipboardContentTests`
Expected: FAIL — `cannot find 'ClipboardContent' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/CreativeNotchCore/Clipboard/ClipboardContent.swift`:

```swift
import Foundation

/// One thing that was on the pasteboard.
///
/// Text and images only. File URLs are the shelf's job, and the shelf does
/// that job by *copying* — a URL held here would go stale the moment the
/// original moved, which is the exact failure the shelf was built to avoid.
///
/// `Hashable` because promotion in `ClipboardStore` is keyed on content
/// equality: re-copying a value already in the ring has to find it.
public enum ClipboardContent: Equatable, Hashable, Sendable {
    case text(String)
    case image(Data, ext: String)

    /// What this costs the ring, in bytes.
    ///
    /// UTF-8 rather than `String.count`: a string of emoji is four bytes
    /// per character, and counting characters would under-report it
    /// fourfold — enough to let a 4 MB paste through a 1 MB cap.
    public var byteCount: Int {
        switch self {
        case .text(let string):   return string.utf8.count
        case .image(let data, _): return data.count
        }
    }

    /// Nothing worth a ring slot.
    ///
    /// Whitespace-only text is what a stray select-and-copy produces;
    /// `Pasteboard+Drop` already refuses it for the shelf, and a fifty-slot
    /// history that can fill with blank lines is worse than useless.
    public var isBlank: Bool {
        switch self {
        case .text(let string):
            return string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .image(let data, _):
            return data.isEmpty
        }
    }
}
```

Create `Sources/CreativeNotchCore/Clipboard/ClipboardLimits.swift`:

```swift
import Foundation

/// The per-entry size caps, and the one predicate that applies them.
///
/// Spec section 5.3. Over-cap content is **skipped, never truncated**: a
/// half-written string pastes back as corrupt data, which is a worse
/// outcome than the entry simply not being there.
///
/// One predicate, two call sites. `NSPasteboard.clipboardCapture()` applies
/// it to raw bytes so it never materialises an image it would throw away,
/// and `ClipboardStore.record` applies it again as the ring's own
/// invariant. Two callers of one function is not duplication — two
/// independent size checks would be.
public enum ClipboardLimits {

    /// 1 MB. Fifty of these is a 50 MB worst case.
    public static let maxTextBytes = 1_000_000

    /// 10 MB. Fifty of these is a 500 MB worst case, which is the real
    /// cost of this module and the number to revisit first if the ring
    /// ever grows a persistence story.
    public static let maxImageBytes = 10_000_000

    public static func acceptsText(byteCount: Int) -> Bool {
        byteCount <= maxTextBytes
    }

    public static func acceptsImage(byteCount: Int) -> Bool {
        byteCount <= maxImageBytes
    }

    /// The caps differ by an order of magnitude, so the kind chooses the
    /// cap here rather than at each call site, where applying the image
    /// cap to text would compile and quietly allow ten times too much.
    public static func accepts(_ content: ClipboardContent) -> Bool {
        guard !content.isBlank else { return false }
        switch content {
        case .text:  return acceptsText(byteCount: content.byteCount)
        case .image: return acceptsImage(byteCount: content.byteCount)
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter ClipboardContentTests`
Expected: PASS, 13 tests.

- [ ] **Step 5: Prove the tests bite**

Change `byteCount` for `.text` to `string.count`. Build, run `swift test --filter ClipboardContentTests`. Expected: `textIsMeasuredInUTF8Bytes` fails. Revert.

Change `accepts` to use `acceptsImage` for both cases. Build, run again. Expected: `eachKindGetsItsOwnCap` fails. Revert.

Change `acceptsText` to `byteCount < maxTextBytes`. Build, run again. Expected: `theTextBoundaryIsInclusive` fails. Revert.

- [ ] **Step 6: Run the full suite**

Run: `swift test`
Expected: PASS, 246 tests.

- [ ] **Step 7: Commit**

```bash
git add Sources/CreativeNotchCore/Clipboard Tests/CreativeNotchCoreTests/ClipboardContentTests.swift
git commit -m "feat: add clipboard content types and their size caps"
```

---

### Task 3: `ClipboardEntry` and `ClipboardStore` — the ring

Fifty entries, newest first, in memory only. There is no `load`, no directory, and no file handle anywhere in this type: "cleared on quit" is not a feature to implement but a consequence of never persisting in the first place.

The one behaviour worth arguing about is **promotion**. Copying something already in the ring moves that entry to the front and refreshes its timestamp rather than appending a second copy. Fifty slots therefore hold fifty *distinct* things, and re-copying one value cannot flush the history. It also makes the app's own paste-back a no-op by construction: writing an entry back to the pasteboard is seen by the poller as an ordinary change, and promotion resolves it to that same entry returning to the front — the correct outcome, reached with no special case.

`@Observable` so the view actually redraws when an entry lands. (`ShelfStore` is not, which is a pre-existing gap recorded under "Deliberately not built" rather than fixed here.)

**Files:**
- Create: `Sources/CreativeNotchCore/Clipboard/ClipboardEntry.swift`
- Create: `Sources/CreativeNotchCore/Clipboard/ClipboardStore.swift`
- Create: `Tests/CreativeNotchCoreTests/ClipboardStoreTests.swift`

**Interfaces:**
- Consumes: `ClipboardContent`, `ClipboardLimits` (Task 2).
- Produces:
  - `struct ClipboardEntry: Identifiable, Equatable, Sendable` with `let id: UUID`, `let content: ClipboardContent`, `var addedAt: Date`, and `init(id:content:addedAt:)`
  - `@MainActor @Observable final class ClipboardStore` with `static let capacity = 50`, `static let maxTotalBytes = 100_000_000`, `init()`, `private(set) var entries: [ClipboardEntry]`, `var totalBytes: Int`, `@discardableResult func record(_ content: ClipboardContent, now: Date) -> ClipboardEntry?`, `func clear()`

- [ ] **Step 1: Write the failing tests**

Create `Tests/CreativeNotchCoreTests/ClipboardStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import CreativeNotchCore

/// Spec section 5.3: a 50-entry ring, in memory only, cleared on quit.
///
/// "Cleared on quit" is not tested here because it is not implemented
/// here — it is a consequence of this type having no persistence at all.
/// The test that guards it is `theStoreNeverTouchesTheFileSystem` below,
/// which pins the *absence* of file APIs in the source.
@MainActor
struct ClipboardStoreTests {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func date(_ offset: TimeInterval) -> Date {
        t0.addingTimeInterval(offset)
    }

    // MARK: - Recording

    @Test func aFreshStoreIsEmpty() {
        #expect(ClipboardStore().entries.isEmpty)
    }

    @Test func recordingPutsTheEntryAtTheFront() {
        let store = ClipboardStore()
        store.record(.text("first"), now: date(0))
        store.record(.text("second"), now: date(1))

        #expect(store.entries.map(\.content) == [.text("second"), .text("first")])
    }

    @Test func theRecordedEntryIsReturned() throws {
        let store = ClipboardStore()
        let entry = try #require(store.record(.text("hello"), now: date(0)))

        #expect(entry.content == .text("hello"))
        #expect(entry.addedAt == date(0))
        #expect(store.entries.first?.id == entry.id)
    }

    @Test func imagesAreRecordedToo() {
        let store = ClipboardStore()
        let data = Data(repeating: 3, count: 128)
        store.record(.image(data, ext: "png"), now: date(0))

        #expect(store.entries.map(\.content) == [.image(data, ext: "png")])
    }

    // MARK: - Limits

    /// The store applies `ClipboardLimits` as its own invariant rather than
    /// trusting its caller. The reader also checks, to avoid materialising
    /// an image it would throw away — but the ring's guarantee about what
    /// it holds has to be enforced by the ring.
    @Test func overCapContentIsRejected() {
        let store = ClipboardStore()
        let huge = String(repeating: "a", count: ClipboardLimits.maxTextBytes + 1)

        #expect(store.record(.text(huge), now: date(0)) == nil)
        #expect(store.entries.isEmpty)
    }

    @Test func blankContentIsRejected() {
        let store = ClipboardStore()
        #expect(store.record(.text("   \n"), now: date(0)) == nil)
        #expect(store.entries.isEmpty)
    }

    /// A rejected entry must not disturb what is already there.
    @Test func aRejectedEntryLeavesTheRingUntouched() {
        let store = ClipboardStore()
        store.record(.text("keeper"), now: date(0))
        store.record(.text(""), now: date(1))

        #expect(store.entries.map(\.content) == [.text("keeper")])
    }

    // MARK: - Promotion

    /// Copy A, B, then A again. The ring holds two entries, not three, and
    /// A is at the front.
    @Test func reCopyingPromotesRatherThanDuplicates() {
        let store = ClipboardStore()
        store.record(.text("A"), now: date(0))
        store.record(.text("B"), now: date(1))
        store.record(.text("A"), now: date(2))

        #expect(store.entries.map(\.content) == [.text("A"), .text("B")])
    }

    /// Promotion refreshes the timestamp: the entry is at the front
    /// *because* it was just copied, and a stale date would contradict the
    /// order the list is displayed in.
    @Test func promotionRefreshesTheTimestamp() {
        let store = ClipboardStore()
        store.record(.text("A"), now: date(0))
        store.record(.text("B"), now: date(1))
        store.record(.text("A"), now: date(2))

        #expect(store.entries.first?.addedAt == date(2))
    }

    /// Promotion keeps the original identity. The view is a `ForEach` over
    /// `Identifiable`, so a fresh id would animate as a delete plus an
    /// insert instead of a move.
    @Test func promotionKeepsTheEntryIdentity() throws {
        let store = ClipboardStore()
        let first = try #require(store.record(.text("A"), now: date(0)))
        store.record(.text("B"), now: date(1))
        let promoted = try #require(store.record(.text("A"), now: date(2)))

        #expect(promoted.id == first.id)
        #expect(store.entries.first?.id == first.id)
    }

    /// Re-copying the front entry — what the app's own paste-back produces
    /// — changes nothing but the timestamp.
    @Test func promotingTheFrontEntryIsStable() {
        let store = ClipboardStore()
        store.record(.text("A"), now: date(0))
        store.record(.text("A"), now: date(1))

        #expect(store.entries.count == 1)
        #expect(store.entries.first?.addedAt == date(1))
    }

    /// Promotion is keyed on content, so an image matches by its bytes.
    @Test func imagesPromoteByTheirBytes() {
        let store = ClipboardStore()
        let data = Data([9, 9, 9])
        store.record(.image(data, ext: "png"), now: date(0))
        store.record(.text("other"), now: date(1))
        store.record(.image(data, ext: "png"), now: date(2))

        #expect(store.entries.count == 2)
        #expect(store.entries.first?.content == .image(data, ext: "png"))
    }

    /// Fifty distinct entries followed by a re-copy of the oldest must not
    /// evict anything: promotion moves, it does not add.
    @Test func promotionNeverEvicts() {
        let store = ClipboardStore()
        for i in 0..<ClipboardStore.capacity {
            store.record(.text("entry \(i)"), now: date(TimeInterval(i)))
        }
        store.record(.text("entry 0"), now: date(999))

        #expect(store.entries.count == ClipboardStore.capacity)
        #expect(store.entries.first?.content == .text("entry 0"))
        #expect(store.entries.contains { $0.content == .text("entry 1") })
    }

    // MARK: - Capacity

    @Test func theCapacityIsWhatTheSpecSays() {
        #expect(ClipboardStore.capacity == 50)
    }

    @Test func theOldestEntryIsEvictedBeyondCapacity() {
        let store = ClipboardStore()
        for i in 0...ClipboardStore.capacity {
            store.record(.text("entry \(i)"), now: date(TimeInterval(i)))
        }

        #expect(store.entries.count == ClipboardStore.capacity)
        #expect(store.entries.first?.content == .text("entry \(ClipboardStore.capacity)"))
        #expect(store.entries.contains { $0.content == .text("entry 0") } == false)
        #expect(store.entries.last?.content == .text("entry 1"))
    }

    @Test func theRingStaysAtCapacityUnderSustainedLoad() {
        let store = ClipboardStore()
        for i in 0..<(ClipboardStore.capacity * 3) {
            store.record(.text("entry \(i)"), now: date(TimeInterval(i)))
        }

        #expect(store.entries.count == ClipboardStore.capacity)
    }

    // MARK: - The byte budget

    /// A count cap alone bounds the ring at `capacity × maxImageBytes` —
    /// 500 MB. That is the number this budget exists to replace, and it
    /// holds however well or badly anything compresses.
    @Test func theBudgetIsWhatTheSpecSays() {
        #expect(ClipboardStore.maxTotalBytes == 100_000_000)
    }

    @Test func totalBytesSumsTheRing() {
        let store = ClipboardStore()
        store.record(.text("abc"), now: date(0))
        store.record(.image(Data(repeating: 0, count: 1000), ext: "png"), now: date(1))

        #expect(store.totalBytes == 1003)
    }

    @Test func anEmptyRingCostsNothing() {
        #expect(ClipboardStore().totalBytes == 0)
    }

    /// Twenty 9 MB images is 180 MB under the count cap alone. The budget
    /// evicts oldest-first until the ring is back under it.
    @Test func theOldestEntriesAreEvictedToStayUnderBudget() {
        let store = ClipboardStore()
        let nineMB = 9_000_000

        for i in 0..<20 {
            var bytes = Data(repeating: 0, count: nineMB)
            bytes[0] = UInt8(i)   // distinct, so nothing promotes
            store.record(.image(bytes, ext: "png"), now: date(TimeInterval(i)))
        }

        #expect(store.totalBytes <= ClipboardStore.maxTotalBytes)
        #expect(store.entries.count < 20)
        // The newest survived; the oldest did not.
        #expect(store.entries.first?.content.byteCount == nineMB)
        #expect(store.entries.count == ClipboardStore.maxTotalBytes / nineMB)
    }

    /// Text never approaches the budget, so a text-only ring is governed
    /// by the count cap exactly as before.
    @Test func aTextOnlyRingIsUnaffectedByTheBudget() {
        let store = ClipboardStore()
        for i in 0..<ClipboardStore.capacity {
            store.record(.text("entry \(i)"), now: date(TimeInterval(i)))
        }

        #expect(store.entries.count == ClipboardStore.capacity)
    }

    /// The entry just copied is never the one evicted. It cannot happen
    /// while the per-entry cap is far below the budget, but a future
    /// change to either number must not turn `record` into a no-op that
    /// silently discards what the user just did.
    @Test func theEntryJustRecordedIsNeverEvicted() throws {
        let store = ClipboardStore()
        let nineMB = 9_000_000

        for i in 0..<30 {
            var bytes = Data(repeating: 0, count: nineMB)
            bytes[0] = UInt8(i)
            let entry = try #require(store.record(.image(bytes, ext: "png"), now: date(TimeInterval(i))))
            #expect(store.entries.first?.id == entry.id)
        }
    }

    // MARK: - Clearing

    @Test func clearingEmptiesTheRing() {
        let store = ClipboardStore()
        store.record(.text("A"), now: date(0))
        store.record(.text("B"), now: date(1))
        store.clear()

        #expect(store.entries.isEmpty)
    }

    @Test func clearingAnEmptyRingIsHarmless() {
        let store = ClipboardStore()
        store.clear()
        #expect(store.entries.isEmpty)
    }

    /// After clearing, the ring behaves like a fresh one — in particular a
    /// value that was there before is recorded again rather than promoted
    /// against a stale entry.
    @Test func theRingIsUsableAfterClearing() {
        let store = ClipboardStore()
        store.record(.text("A"), now: date(0))
        store.clear()
        store.record(.text("A"), now: date(1))

        #expect(store.entries.map(\.content) == [.text("A")])
    }

    // MARK: - The in-memory guarantee

    /// The strongest claim in `SECURITY.md` is that captured content never
    /// reaches disk. That is guaranteed by this type having no persistence
    /// code at all, which is a property of the source rather than of any
    /// behaviour — so it is checked by reading the source.
    ///
    /// `ShelfStore` is the counter-example living one directory away: the
    /// same shape of type, with `FileManager` throughout. Nothing but this
    /// test stops the two converging.
    @Test func theStoreNeverTouchesTheFileSystem() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // .../Tests/CreativeNotchCoreTests
            .deletingLastPathComponent()   // .../Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Sources/CreativeNotchCore/Clipboard/ClipboardStore.swift")

        let text = try String(contentsOf: source, encoding: .utf8)
        let banned = ["FileManager", "UserDefaults", "URL(fileURLWithPath", "write(to", "NSKeyedArchiver"]

        for token in banned {
            #expect(text.contains(token) == false, "ClipboardStore must stay in memory: found \(token)")
        }
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter ClipboardStoreTests`
Expected: FAIL — `cannot find 'ClipboardStore' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/CreativeNotchCore/Clipboard/ClipboardEntry.swift`:

```swift
import Foundation

/// One slot in the clipboard ring.
///
/// `addedAt` is a `var` because promotion refreshes it: an entry sitting at
/// the front because it was just re-copied would otherwise show a
/// timestamp from the first time it was seen, contradicting the order the
/// list is displayed in.
///
/// `id` survives promotion. The view is a `ForEach` over `Identifiable`,
/// and a fresh id would animate a move as a delete plus an insert.
public struct ClipboardEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let content: ClipboardContent
    public var addedAt: Date

    public init(id: UUID, content: ClipboardContent, addedAt: Date) {
        self.id = id
        self.content = content
        self.addedAt = addedAt
    }
}
```

Create `Sources/CreativeNotchCore/Clipboard/ClipboardStore.swift`:

```swift
import Foundation
import Observation

/// The clipboard history: fifty entries, newest first, in memory only.
///
/// There is no `load`, no directory, and no file handle in this type.
/// "Cleared on quit" is not a feature implemented here — it is what
/// happens when nothing is ever written down. `SECURITY.md` makes that a
/// promise, and `ClipboardStoreTests.theStoreNeverTouchesTheFileSystem`
/// pins it by reading this file.
///
/// `@Observable`, unlike `ShelfStore`, so the view redraws when an entry
/// lands without the poller having to tell it to.
///
/// `@MainActor` because every caller is: the poller, the view, and the
/// menu bar item.
@MainActor
@Observable
public final class ClipboardStore {

    public static let capacity = 50

    /// The ceiling on everything the ring holds, together.
    ///
    /// A count cap alone bounds this at `capacity × maxImageBytes` — half
    /// a gigabyte, resident for the life of the process. That is a real
    /// number rather than a pathological one: an uncompressed retina
    /// screenshot is tens of megabytes, and this app is aimed at people
    /// who copy them all day.
    ///
    /// Transcoding to PNG at capture (see `NSPasteboard.clipboardCapture`)
    /// makes the typical entry roughly a tenth of that. This is the
    /// guarantee that holds even when it doesn't — a screenshot of noise
    /// compresses to nothing at all.
    public static let maxTotalBytes = 100_000_000

    /// Newest first.
    public private(set) var entries: [ClipboardEntry] = []

    public var totalBytes: Int {
        entries.reduce(0) { $0 + $1.content.byteCount }
    }

    public init() {}

    /// Records `content`, returning the entry it became — or `nil` if the
    /// ring refused it.
    ///
    /// Re-copying something already here **promotes** it: the existing
    /// entry moves to the front and its timestamp is refreshed, rather
    /// than a second copy being appended. Fifty slots therefore hold fifty
    /// distinct things, and re-copying one value cannot flush the history.
    ///
    /// It also makes the app's own paste-back a no-op by construction.
    /// Writing an entry back to the pasteboard bumps `changeCount`, so the
    /// poller sees its own write; promotion resolves that to the same
    /// entry returning to the front, which is the correct outcome anyway.
    /// The alternative — suppressing the change count we ourselves caused
    /// — is a special case that would have to stay correct forever.
    @discardableResult
    public func record(_ content: ClipboardContent, now: Date) -> ClipboardEntry? {
        // The ring enforces its own invariant rather than trusting the
        // caller. `NSPasteboard.clipboardCapture()` checks too, but only
        // so it can avoid materialising an image it would throw away.
        guard ClipboardLimits.accepts(content) else { return nil }

        if let index = entries.firstIndex(where: { $0.content == content }) {
            var promoted = entries.remove(at: index)
            promoted.addedAt = now
            entries.insert(promoted, at: 0)
            return promoted
        }

        let entry = ClipboardEntry(id: UUID(), content: content, addedAt: now)
        entries.insert(entry, at: 0)
        evictBeyondLimits()
        return entry
    }

    public func clear() {
        entries.removeAll()
    }

    /// Eviction happens only after an insert, never on a timer: a ring can
    /// only grow when something is added to it.
    ///
    /// Two limits, both oldest-first. The count cap is what the spec
    /// describes; the byte budget is what actually bounds memory, since
    /// fifty entries of wildly different sizes is not a fixed cost.
    ///
    /// The `count > 1` guard means the entry just recorded is never the
    /// one evicted. It is unreachable while the per-entry cap is far below
    /// the budget — but without it, raising `maxImageBytes` past
    /// `maxTotalBytes` some day would turn `record` into a no-op that
    /// silently discarded exactly what the user had just copied.
    private func evictBeyondLimits() {
        while entries.count > Self.capacity {
            entries.removeLast()
        }
        while entries.count > 1, totalBytes > Self.maxTotalBytes {
            entries.removeLast()
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter ClipboardStoreTests`
Expected: PASS, 25 tests.

- [ ] **Step 5: Prove the tests bite**

Delete the promotion branch so every record inserts a fresh entry. Build, run `swift test --filter ClipboardStoreTests`. Expected: `reCopyingPromotesRatherThanDuplicates`, `promotionKeepsTheEntryIdentity`, `promotingTheFrontEntryIsStable`, `imagesPromoteByTheirBytes` and `promotionNeverEvicts` fail. Revert.

Change promotion to leave `addedAt` alone. Build, run again. Expected: `promotionRefreshesTheTimestamp` fails. Revert.

Change both loops in `evictBeyondLimits` to `removeFirst()`. Build, run again. Expected: `theOldestEntryIsEvictedBeyondCapacity` fails. Revert.

Delete the byte-budget loop from `evictBeyondLimits`. Build, run again. Expected: `theOldestEntriesAreEvictedToStayUnderBudget` fails. Revert.

Change the byte-budget loop's guard from `entries.count > 1` to `!entries.isEmpty` and temporarily set `maxTotalBytes = 1000`. Build, run again. Expected: `theEntryJustRecordedIsNeverEvicted` fails. Revert both.

- [ ] **Step 6: Run the full suite**

Run: `swift test`
Expected: PASS, 271 tests.

- [ ] **Step 7: Commit**

```bash
git add Sources/CreativeNotchCore/Clipboard Tests/CreativeNotchCoreTests/ClipboardStoreTests.swift
git commit -m "feat: add the 50-entry in-memory clipboard ring"
```

---

### Task 4: `ClipboardPollSchedule` — how often, and why not more often

The whole justification for admitting a poller into this project sits in this one function. It is pure maths over two inputs, so it is tested exhaustively without a clock, a timer, or a battery.

**Files:**
- Create: `Sources/CreativeNotchCore/Clipboard/ClipboardPollSchedule.swift`
- Create: `Tests/CreativeNotchCoreTests/ClipboardPollScheduleTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `enum ClipboardPollSchedule` with `static let activeInterval: TimeInterval = 0.75`, `static let idleInterval: TimeInterval = 3.0`, `static let idleAfter: TimeInterval = 120`, `static let lowPowerFloor: TimeInterval = 2.0`, and `static func interval(sinceLastChange: TimeInterval, lowPower: Bool) -> TimeInterval`

- [ ] **Step 1: Write the failing tests**

Create `Tests/CreativeNotchCoreTests/ClipboardPollScheduleTests.swift`:

```swift
import Foundation
import Testing
@testable import CreativeNotchCore

/// Spec section 5.3: 0.75s while active, backing off to 3s after two
/// minutes with no change, with a 2s floor under Low Power Mode.
///
/// This is the entire justification for admitting a timer into a project
/// whose stated rule is that it does not poll, so every number in it is
/// pinned rather than assumed.
struct ClipboardPollScheduleTests {

    @Test func theIntervalsAreWhatTheSpecSays() {
        #expect(ClipboardPollSchedule.activeInterval == 0.75)
        #expect(ClipboardPollSchedule.idleInterval == 3.0)
        #expect(ClipboardPollSchedule.idleAfter == 120)
        #expect(ClipboardPollSchedule.lowPowerFloor == 2.0)
    }

    @Test func aRecentChangePollsFast() {
        #expect(ClipboardPollSchedule.interval(sinceLastChange: 0, lowPower: false) == 0.75)
        #expect(ClipboardPollSchedule.interval(sinceLastChange: 30, lowPower: false) == 0.75)
    }

    @Test func twoQuietMinutesBacksOff() {
        #expect(ClipboardPollSchedule.interval(sinceLastChange: 200, lowPower: false) == 3.0)
    }

    /// Exactly at the threshold the back-off applies; a moment before it
    /// does not. Without this pair, `>` and `>=` are indistinguishable.
    @Test func theBackOffBoundaryIsInclusive() {
        let at = ClipboardPollSchedule.idleAfter
        #expect(ClipboardPollSchedule.interval(sinceLastChange: at, lowPower: false) == 3.0)
        #expect(ClipboardPollSchedule.interval(sinceLastChange: at - 0.001, lowPower: false) == 0.75)
    }

    /// The back-off is a function of elapsed time, so "resets on any
    /// change" is expressed by the caller passing a smaller elapsed value
    /// rather than by any state held here. This is the test that says so.
    @Test func aChangeResetsTheBackOff() {
        #expect(ClipboardPollSchedule.interval(sinceLastChange: 500, lowPower: false) == 3.0)
        #expect(ClipboardPollSchedule.interval(sinceLastChange: 0, lowPower: false) == 0.75)
    }

    /// Low Power raises the *floor*. It does not set the interval, which
    /// is why the already-slower idle rate is left alone rather than being
    /// pulled down to 2s.
    @Test func lowPowerRaisesTheActiveRateToTheFloor() {
        #expect(ClipboardPollSchedule.interval(sinceLastChange: 0, lowPower: true) == 2.0)
    }

    @Test func lowPowerDoesNotSpeedUpTheIdleRate() {
        #expect(ClipboardPollSchedule.interval(sinceLastChange: 200, lowPower: true) == 3.0)
    }

    /// Under Low Power the interval never drops below the floor, whatever
    /// the elapsed time.
    @Test func theFloorHoldsAcrossTheWholeRange() {
        for elapsed in stride(from: 0.0, through: 300.0, by: 7.5) {
            let interval = ClipboardPollSchedule.interval(sinceLastChange: elapsed, lowPower: true)
            #expect(interval >= ClipboardPollSchedule.lowPowerFloor)
        }
    }

    /// The interval is never faster than the active rate and never slower
    /// than the idle rate, whatever the inputs — including nonsense ones.
    @Test func theIntervalIsAlwaysWithinBounds() {
        for elapsed in stride(from: -50.0, through: 500.0, by: 12.5) {
            for lowPower in [true, false] {
                let interval = ClipboardPollSchedule.interval(
                    sinceLastChange: elapsed,
                    lowPower: lowPower
                )
                #expect(interval >= ClipboardPollSchedule.activeInterval)
                #expect(interval <= ClipboardPollSchedule.idleInterval)
            }
        }
    }

    /// Clocks are not guaranteed monotonic across sources. A negative
    /// elapsed time is nonsense, and nonsense must mean "poll at the
    /// normal rate", never "back off forever".
    @Test func aNegativeElapsedTimePollsAtTheActiveRate() {
        #expect(ClipboardPollSchedule.interval(sinceLastChange: -10, lowPower: false) == 0.75)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter ClipboardPollScheduleTests`
Expected: FAIL — `cannot find 'ClipboardPollSchedule' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/CreativeNotchCore/Clipboard/ClipboardPollSchedule.swift`:

```swift
import Foundation

/// How often the clipboard is read, and why that is defensible.
///
/// `NSPasteboard` has no change notification, so this module is the
/// project's one admitted poller (spec section 5.3). Everything that makes
/// that acceptable is here, as pure arithmetic over two inputs: a fast
/// rate while things are happening, a back-off when they are not, and a
/// floor when the machine is trying to save power.
///
/// There is no state. "Resets on any change" is expressed by the caller
/// passing a smaller `sinceLastChange`, which keeps the whole policy
/// testable without a clock.
public enum ClipboardPollSchedule {

    /// While something is happening.
    public static let activeInterval: TimeInterval = 0.75

    /// After a quiet spell.
    public static let idleInterval: TimeInterval = 3.0

    /// How long a quiet spell has to be. Deliberately not user-idle:
    /// detecting that means polling `CGEventSource`, which would violate
    /// the rule this back-off exists to serve. Time since the last
    /// *clipboard* change is a proxy this module already has for free.
    public static let idleAfter: TimeInterval = 120

    /// The slowest this is allowed to go under Low Power Mode.
    public static let lowPowerFloor: TimeInterval = 2.0

    /// Low Power raises the floor rather than setting the interval, so the
    /// already-slower idle rate is left alone instead of being pulled
    /// *down* to 2s — which is what a plain assignment would do.
    ///
    /// A negative `sinceLastChange` is nonsense rather than an eternity:
    /// clocks are not guaranteed monotonic across sources, and the failure
    /// mode of reading it as "very idle" is a poller that backs off and
    /// never recovers.
    public static func interval(sinceLastChange: TimeInterval, lowPower: Bool) -> TimeInterval {
        let base = sinceLastChange >= idleAfter ? idleInterval : activeInterval
        return lowPower ? max(base, lowPowerFloor) : base
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter ClipboardPollScheduleTests`
Expected: PASS, 10 tests.

- [ ] **Step 5: Prove the tests bite**

Change the Low Power branch from `max(base, lowPowerFloor)` to `lowPowerFloor`. Build, run `swift test --filter ClipboardPollScheduleTests`. Expected: `lowPowerDoesNotSpeedUpTheIdleRate` fails. Revert.

Change `>= idleAfter` to `> idleAfter`. Build, run again. Expected: `theBackOffBoundaryIsInclusive` fails. Revert.

- [ ] **Step 6: Run the full suite**

Run: `swift test`
Expected: PASS, 281 tests.

- [ ] **Step 7: Commit**

```bash
git add Sources/CreativeNotchCore/Clipboard/ClipboardPollSchedule.swift Tests/CreativeNotchCoreTests/ClipboardPollScheduleTests.swift
git commit -m "feat: add the clipboard poll schedule and its idle back-off"
```

---

### Task 5: `NSPasteboard.clipboardCapture()` — the read, and everything it refuses

This is the security boundary of the module. The skip-type check runs **first**, before any content is read, so a password manager's entry is never materialised at all.

Tested against `NSPasteboard(name:)` with a per-test UUID, exactly as `PasteboardDropTests` does, so the machine's real clipboard is never touched.

**Files:**
- Create: `Sources/CreativeNotchUI/Clipboard/Pasteboard+Clipboard.swift`
- Create: `Tests/CreativeNotchUITests/PasteboardClipboardTests.swift`

**Interfaces:**
- Consumes: `ClipboardContent`, `ClipboardLimits` (Task 2).
- Produces:
  - `NSPasteboard.clipboardCapture() -> ClipboardContent?`
  - `NSPasteboard.PasteboardType.nsConcealed`, `.nsTransient`, `.nsAutoGenerated`
  - `NSPasteboard.write(_ content: ClipboardContent)`

- [ ] **Step 1: Write the failing tests**

Create `Tests/CreativeNotchUITests/PasteboardClipboardTests.swift`:

```swift
import AppKit
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// Converting an `NSPasteboard` into something the ring will accept.
///
/// A named pasteboard is used rather than the general one so the tests
/// cannot disturb the machine's actual clipboard.
///
/// This is the security boundary of the module: the skip-type check runs
/// before any content is read, so a password manager's entry is never
/// materialised at all.
@MainActor
struct PasteboardClipboardTests {

    private func makePasteboard() -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("CreativeNotchClipTest-\(UUID().uuidString)"))
        pb.clearContents()
        return pb
    }

    private func pngData() -> Data {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return Data() }
        return png
    }

    // MARK: - The skip types

    /// The convention password managers use. Most clipboard managers
    /// ignore it and quietly write passwords to disk; this one is the
    /// reason the module exists in the shape it does.
    @Test func concealedContentIsNeverCaptured() {
        let pb = makePasteboard()
        pb.setString("hunter2", forType: .nsConcealed)
        pb.setString("hunter2", forType: .string)

        #expect(pb.clipboardCapture() == nil)
    }

    @Test func transientContentIsNeverCaptured() {
        let pb = makePasteboard()
        pb.setString("temporary", forType: .nsTransient)
        pb.setString("temporary", forType: .string)

        #expect(pb.clipboardCapture() == nil)
    }

    @Test func autoGeneratedContentIsNeverCaptured() {
        let pb = makePasteboard()
        pb.setString("generated", forType: .nsAutoGenerated)
        pb.setString("generated", forType: .string)

        #expect(pb.clipboardCapture() == nil)
    }

    @Test func theSkipTypesUseTheConventionalIdentifiers() {
        #expect(NSPasteboard.PasteboardType.nsConcealed.rawValue == "org.nspasteboard.ConcealedType")
        #expect(NSPasteboard.PasteboardType.nsTransient.rawValue == "org.nspasteboard.TransientType")
        #expect(NSPasteboard.PasteboardType.nsAutoGenerated.rawValue == "org.nspasteboard.AutoGeneratedType")
    }

    /// A concealed marker suppresses an *image* too. Checking only the
    /// string path would leave a copied secret screenshot captured.
    @Test func concealedSuppressesImagesAsWell() {
        let pb = makePasteboard()
        pb.setData(pngData(), forType: .png)
        pb.setString("", forType: .nsConcealed)

        #expect(pb.clipboardCapture() == nil)
    }

    // MARK: - Text

    @Test func plainTextIsCaptured() {
        let pb = makePasteboard()
        pb.setString("hello there", forType: .string)

        #expect(pb.clipboardCapture() == .text("hello there"))
    }

    @Test func whitespaceOnlyTextIsIgnored() {
        let pb = makePasteboard()
        pb.setString("   \n  ", forType: .string)

        #expect(pb.clipboardCapture() == nil)
    }

    @Test func anEmptyPasteboardYieldsNothing() {
        #expect(makePasteboard().clipboardCapture() == nil)
    }

    /// Over-cap text is skipped outright rather than truncated: a
    /// half-written string pastes back as corrupt data.
    @Test func overSizedTextIsSkippedNotTruncated() {
        let pb = makePasteboard()
        pb.setString(String(repeating: "a", count: ClipboardLimits.maxTextBytes + 1), forType: .string)

        #expect(pb.clipboardCapture() == nil)
    }

    // MARK: - Images

    @Test func pngDataIsCaptured() throws {
        let pb = makePasteboard()
        let data = pngData()
        pb.setData(data, forType: .png)

        #expect(pb.clipboardCapture() == .image(data, ext: "png"))
    }

    /// macOS screenshots reach the pasteboard as TIFF, and `NSPasteboard`
    /// TIFF is **uncompressed** — roughly `width × height × 4` bytes. A
    /// 14" MacBook Pro full-screen grab is about 24 MB that way, which
    /// would blow straight through the 10 MB cap and be silently dropped.
    /// The same image as PNG is a couple of megabytes.
    ///
    /// So TIFF is re-encoded before the cap is applied, and what lands in
    /// the ring is always PNG.
    @Test func tiffIsTranscodedToPNG() throws {
        let pb = makePasteboard()
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.blue.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        pb.setData(tiff, forType: .tiff)

        let captured = try #require(pb.clipboardCapture())
        guard case .image(let data, let ext) = captured else {
            Issue.record("expected an image")
            return
        }

        #expect(ext == "png")
        #expect(data != tiff)
        // A PNG signature, so this is genuinely re-encoded rather than
        // TIFF bytes relabelled.
        #expect(data.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
    }

    /// The point of transcoding: a large flat image is far over the cap as
    /// TIFF and comfortably under it as PNG. Judged after re-encoding, it
    /// is kept — judged before, it would have been thrown away.
    @Test func aLargeScreenshotSurvivesBecauseItIsTranscoded() throws {
        // 1600×1600 × 4 bytes ≈ 10.2 MB of TIFF, just over the cap.
        let image = NSImage(size: NSSize(width: 1600, height: 1600))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 1600, height: 1600).fill()
        image.unlockFocus()

        let tiff = try #require(image.tiffRepresentation)
        #expect(tiff.count > ClipboardLimits.maxImageBytes)

        let pb = makePasteboard()
        pb.setData(tiff, forType: .tiff)

        let captured = try #require(pb.clipboardCapture())
        #expect(captured.byteCount < ClipboardLimits.maxImageBytes)
    }

    /// PNG already on the pasteboard is taken as-is. Re-encoding it would
    /// cost time and gain nothing.
    @Test func existingPNGIsNotReEncoded() {
        let pb = makePasteboard()
        let data = pngData()
        pb.setData(data, forType: .png)
        pb.setData(Data([0x4D, 0x4D]), forType: .tiff)

        #expect(pb.clipboardCapture() == .image(data, ext: "png"))
    }

    /// Undecodable bytes claiming to be TIFF must yield nothing rather
    /// than crashing or storing garbage.
    @Test func unreadableImageDataIsIgnored() {
        let pb = makePasteboard()
        pb.setData(Data([0x00, 0x01, 0x02, 0x03]), forType: .tiff)

        #expect(pb.clipboardCapture() == nil)
    }

    /// An image and its alt text are often both present. The image is the
    /// thing that was copied.
    @Test func anImageWinsOverAccompanyingText() {
        let pb = makePasteboard()
        let data = pngData()
        pb.setData(data, forType: .png)
        pb.setString("a red square", forType: .string)

        #expect(pb.clipboardCapture() == .image(data, ext: "png"))
    }

    @Test func overSizedImagesAreSkipped() {
        let pb = makePasteboard()
        pb.setData(Data(repeating: 0, count: ClipboardLimits.maxImageBytes + 1), forType: .png)

        #expect(pb.clipboardCapture() == nil)
    }

    // MARK: - File URLs

    /// Copying a file in Finder puts its path on the pasteboard as a
    /// string too. Capturing that would fill the clipboard history with
    /// paths for something the shelf already handles properly — by
    /// copying the file, so the entry survives the original moving.
    @Test func copiedFilesAreLeftToTheShelf() {
        let pb = makePasteboard()
        pb.writeObjects([URL(fileURLWithPath: "/tmp/thing.pdf") as NSURL])
        pb.setString("/tmp/thing.pdf", forType: .string)

        #expect(pb.clipboardCapture() == nil)
    }

    // MARK: - Writing back

    /// Clicking an entry writes it back and nothing more. No synthesized
    /// paste keystroke: spec section 6 commits this module to needing no
    /// permission, and key synthesis would require Accessibility.
    @Test func writingTextBackRoundTrips() {
        let pb = makePasteboard()
        pb.write(.text("round trip"))

        #expect(pb.string(forType: .string) == "round trip")
        #expect(pb.clipboardCapture() == .text("round trip"))
    }

    @Test func writingAnImageBackRoundTrips() {
        let pb = makePasteboard()
        let data = pngData()
        pb.write(.image(data, ext: "png"))

        #expect(pb.data(forType: .png) == data)
        #expect(pb.clipboardCapture() == .image(data, ext: "png"))
    }

    /// Writing clears what was there first, so a write cannot leave the
    /// previous entry's types alongside the new one — which would make the
    /// next capture return the wrong thing.
    @Test func writingReplacesTheWholePasteboard() {
        let pb = makePasteboard()
        pb.setString("old", forType: .string)
        pb.write(.image(pngData(), ext: "png"))

        #expect(pb.string(forType: .string) == nil)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter PasteboardClipboardTests`
Expected: FAIL — `value of type 'NSPasteboard' has no member 'clipboardCapture'`.

- [ ] **Step 3: Write the implementation**

Create `Sources/CreativeNotchUI/Clipboard/Pasteboard+Clipboard.swift`:

```swift
import AppKit
import CreativeNotchCore

public extension NSPasteboard.PasteboardType {

    /// The convention password managers use to say "do not record this".
    /// Most clipboard managers ignore it and quietly write passwords to
    /// disk; honouring it is half of why this module exists.
    static let nsConcealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// Content that is on the pasteboard only in passing.
    static let nsTransient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    /// Content an app put there on the user's behalf rather than because
    /// they asked for it.
    static let nsAutoGenerated = NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")
}

public extension NSPasteboard {

    /// Every type this module refuses to look at.
    static let skippedTypes: [NSPasteboard.PasteboardType] = [
        .nsConcealed, .nsTransient, .nsAutoGenerated
    ]

    /// What this pasteboard offers the clipboard ring, with AppKit
    /// stripped away — or `nil` if it offers nothing worth keeping.
    ///
    /// The order is the security order:
    ///
    /// 1. **Skip types first**, before a single byte of content is read.
    ///    A password manager's entry is never materialised at all, which
    ///    is a stronger guarantee than reading it and discarding it.
    /// 2. **File URLs** mean the shelf's job, not this one. Copying a file
    ///    in Finder also puts its path on as a string, and capturing that
    ///    would fill the history with paths for something the shelf
    ///    already handles properly — by copying the file, so the entry
    ///    survives the original moving.
    /// 3. **Images before text**, because an image and its alt text are
    ///    often both present and the image is what was copied.
    ///
    /// Images are always stored as PNG. `NSPasteboard` TIFF is
    /// uncompressed — roughly `width × height × 4` bytes, so a 14"
    /// MacBook Pro screenshot arrives as about 24 MB. Judged at that size
    /// it would fail the 10 MB cap and be silently dropped, which is the
    /// wrong answer for the single most common thing this app will be
    /// asked to remember. Re-encoded first, the same image is a couple of
    /// megabytes and is kept.
    ///
    /// The cap is therefore applied to what the ring will actually hold,
    /// not to what the pasteboard happened to hand over.
    func clipboardCapture() -> ClipboardContent? {
        let available = types ?? []
        guard !available.contains(where: { Self.skippedTypes.contains($0) }) else { return nil }

        if let urls = readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           !urls.isEmpty {
            return nil
        }

        // PNG already on the pasteboard is taken as-is: re-encoding it
        // would cost time and gain nothing.
        if let png = data(forType: .png) {
            let content = ClipboardContent.image(png, ext: "png")
            return ClipboardLimits.accepts(content) ? content : nil
        }

        if let tiff = data(forType: .tiff) {
            guard let png = Self.pngData(fromTIFF: tiff) else { return nil }
            let content = ClipboardContent.image(png, ext: "png")
            return ClipboardLimits.accepts(content) ? content : nil
        }

        if let text = string(forType: .string) {
            let content = ClipboardContent.text(text)
            return ClipboardLimits.accepts(content) ? content : nil
        }

        return nil
    }

    /// Re-encodes uncompressed pasteboard TIFF as PNG.
    ///
    /// Runs on the main actor, where a large image costs on the order of
    /// 50–150 ms. That is acceptable because image copies are rare — a
    /// few a minute at the very most — but it is the thread driving the
    /// notch animation, so if it ever hitches visibly this is the thing to
    /// move off it. Measure before assuming it does.
    ///
    /// Returns `nil` for bytes that do not decode, so undecodable data
    /// yields no entry rather than a garbage one.
    static func pngData(fromTIFF tiff: Data) -> Data? {
        guard let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Puts an entry back on the pasteboard, and does nothing else.
    ///
    /// No synthesized paste keystroke: spec section 6 commits this module
    /// to needing no permission, and key synthesis would require
    /// Accessibility. The user pastes it themselves.
    ///
    /// `clearContents` first, so a write cannot leave the previous entry's
    /// types sitting alongside the new one — which would make the very
    /// next capture return the wrong thing.
    func write(_ content: ClipboardContent) {
        clearContents()
        switch content {
        case .text(let string):
            setString(string, forType: .string)
        case .image(let data, let ext):
            setData(data, forType: ext == "tiff" ? .tiff : .png)
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter PasteboardClipboardTests`
Expected: PASS, 20 tests.

- [ ] **Step 5: Prove the tests bite**

Move the skip-type guard to *after* the image and text reads. Build, run `swift test --filter PasteboardClipboardTests`. Expected: the three skip-type tests and `concealedSuppressesImagesAsWell` fail. Revert.

Delete the file-URL guard. Build, run again. Expected: `copiedFilesAreLeftToTheShelf` fails. Revert.

Change the TIFF branch to store `tiff` directly as `.image(tiff, ext: "tiff")` instead of transcoding — the pre-review behaviour. Build, run again. Expected: `tiffIsTranscodedToPNG` and `aLargeScreenshotSurvivesBecauseItIsTranscoded` fail. Revert.

In `clipboardCapture`, apply `ClipboardLimits.accepts` to the TIFF bytes *before* transcoding. Build, run again. Expected: `aLargeScreenshotSurvivesBecauseItIsTranscoded` fails — the exact bug the transcode exists to prevent. Revert.

Delete `clearContents()` from `write`. Build, run again. Expected: `writingReplacesTheWholePasteboard` fails. Revert.

- [ ] **Step 6: Run the full suite**

Run: `swift test`
Expected: PASS, 301 tests.

- [ ] **Step 7: Commit**

```bash
git add Sources/CreativeNotchUI/Clipboard Tests/CreativeNotchUITests/PasteboardClipboardTests.swift
git commit -m "feat: read the pasteboard, refusing concealed and transient types"
```

---

### Task 6: `SystemActivityObserver` — where the events actually come from

A thin AppKit wrapper feeding `SystemActivityReducer`. All the judgement is in Core; this only translates notification names.

The lifecycle test is identity-based, following the precedent set by `VolumeObserver`, `BrightnessObserver` and `MediaKeyMonitor` — all three of which once had a `stop()` that silently forgot one of the things `start()` registered.

**Files:**
- Create: `Sources/CreativeNotchUI/SystemActivityObserver.swift`
- Create: `Tests/CreativeNotchUITests/SystemActivityObserverTests.swift`

**Interfaces:**
- Consumes: `SystemActivity`, `SystemActivityEvent`, `SystemActivityReducer` (Task 1).
- Produces:
  - `@MainActor final class SystemActivityObserver` with `init()`, `var onChange: ((SystemActivity) -> Void)?`, `private(set) var activity: SystemActivity`, `func start()`, `func stop()`, and internal `func handle(_ event: SystemActivityEvent)`
  - `SystemActivityObserver.tokenCount: Int` (internal, for the lifecycle test)

- [ ] **Step 1: Write the failing tests**

Create `Tests/CreativeNotchUITests/SystemActivityObserverTests.swift`:

```swift
import AppKit
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// The AppKit half of spec section 4.7. All judgement lives in
/// `SystemActivityReducer`; this only translates notification names, so
/// what is tested here is the translation and the lifecycle.
@MainActor
struct SystemActivityObserverTests {

    @Test func itStartsActive() {
        #expect(SystemActivityObserver().activity == .active)
    }

    @Test func lockingIsReported() {
        let observer = SystemActivityObserver()
        var seen: [SystemActivity] = []
        observer.onChange = { seen.append($0) }

        observer.handle(.screenLocked)

        #expect(observer.activity == .locked)
        #expect(seen == [.locked])
    }

    @Test func theFullSleepCycleIsReported() {
        let observer = SystemActivityObserver()
        var seen: [SystemActivity] = []
        observer.onChange = { seen.append($0) }

        observer.handle(.willSleep)
        observer.handle(.screenLocked)
        observer.handle(.didWake)
        observer.handle(.screenUnlocked)

        #expect(seen == [.asleep, .locked, .active])
        #expect(observer.activity == .active)
    }

    /// Only *changes* are reported. `screenIsLocked` can be delivered more
    /// than once, and the consumer tears down and rebuilds a timer on each
    /// call — so a repeat would restart the poll clock for no reason.
    @Test func unchangedActivityIsNotReported() {
        let observer = SystemActivityObserver()
        var count = 0
        observer.onChange = { _ in count += 1 }

        observer.handle(.screenLocked)
        observer.handle(.screenLocked)

        #expect(count == 1)
    }

    /// `start()` and `stop()` must register and remove the *same* set.
    /// Three observers in this codebase have shipped a `stop()` that
    /// forgot one of them; each was found by a test shaped like this.
    @Test func stoppingRemovesEverythingStartingAdded() {
        let observer = SystemActivityObserver()
        #expect(observer.tokenCount == 0)

        observer.start()
        #expect(observer.tokenCount == 4)

        observer.stop()
        #expect(observer.tokenCount == 0)
    }

    @Test func startingTwiceDoesNotStackObservers() {
        let observer = SystemActivityObserver()
        observer.start()
        observer.start()

        #expect(observer.tokenCount == 4)
        observer.stop()
        #expect(observer.tokenCount == 0)
    }

    @Test func stoppingWithoutStartingIsHarmless() {
        let observer = SystemActivityObserver()
        observer.stop()
        #expect(observer.tokenCount == 0)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter SystemActivityObserverTests`
Expected: FAIL — `cannot find 'SystemActivityObserver' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/CreativeNotchUI/SystemActivityObserver.swift`:

```swift
import AppKit
import CreativeNotchCore

/// Turns workspace and distributed notifications into a `SystemActivity`.
///
/// A dumb source, like the HUD's observers: every judgement — including
/// the sleep-outranks-lock precedence that makes waking behind a lock
/// screen safe — lives in `SystemActivityReducer`, in Core, where it runs
/// headlessly.
///
/// Screen lock has no `NSWorkspace` notification. It arrives on
/// `DistributedNotificationCenter` instead, which is why the tokens are
/// stored with the centre they came from: removing a distributed observer
/// from `NSWorkspace.shared.notificationCenter` silently does nothing.
@MainActor
public final class SystemActivityObserver {

    public var onChange: ((SystemActivity) -> Void)?

    public private(set) var activity: SystemActivity = .active

    private var reducer = SystemActivityReducer()
    private var tokens: [(token: NSObjectProtocol, center: NotificationCenter)] = []

    /// Internal rather than private so the lifecycle is provable.
    /// `VolumeObserver`, `BrightnessObserver` and `MediaKeyMonitor` each
    /// shipped a `stop()` that forgot one of the things `start()`
    /// registered, and each was caught by a count like this.
    var tokenCount: Int { tokens.count }

    public init() {}

    public func start() {
        // Re-registering must not stack: `start()` being called twice is a
        // wiring mistake, not a reason to receive every event twice.
        stop()

        let workspace = NSWorkspace.shared.notificationCenter
        observe(NSWorkspace.willSleepNotification, on: workspace, as: .willSleep)
        observe(NSWorkspace.didWakeNotification, on: workspace, as: .didWake)

        let distributed = DistributedNotificationCenter.default()
        observe(Notification.Name("com.apple.screenIsLocked"), on: distributed, as: .screenLocked)
        observe(Notification.Name("com.apple.screenIsUnlocked"), on: distributed, as: .screenUnlocked)
    }

    public func stop() {
        for entry in tokens {
            entry.center.removeObserver(entry.token)
        }
        tokens.removeAll()
    }

    /// Internal so tests can drive the whole path without posting real
    /// system notifications, which cannot be synthesised for lock and
    /// unlock.
    func handle(_ event: SystemActivityEvent) {
        let next = reducer.apply(event)
        // Only changes are reported. `screenIsLocked` can arrive more than
        // once, and the consumer rebuilds a timer on each call — a repeat
        // would restart the poll clock for nothing.
        guard next != activity else { return }
        activity = next
        onChange?(next)
    }

    private func observe(
        _ name: Notification.Name,
        on center: NotificationCenter,
        as event: SystemActivityEvent
    ) {
        // `queue: .main` guarantees these run on the main thread, but the
        // closure type is `@Sendable` so the compiler cannot see it.
        // `assumeIsolated` asserts the guarantee the API already gives
        // rather than deferring to a fresh `Task`, which would change when
        // the suspension happens relative to the notification.
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.handle(event) }
        }
        tokens.append((token, center))
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter SystemActivityObserverTests`
Expected: PASS, 7 tests.

- [ ] **Step 5: Prove the tests bite**

Delete the two `DistributedNotificationCenter` registrations from `start()`. Build, run `swift test --filter SystemActivityObserverTests`. Expected: `stoppingRemovesEverythingStartingAdded` and `startingTwiceDoesNotStackObservers` fail. Revert.

Delete the `guard next != activity` line. Build, run again. Expected: `unchangedActivityIsNotReported` and `theFullSleepCycleIsReported` fail. Revert.

Delete the leading `stop()` in `start()`. Build, run again. Expected: `startingTwiceDoesNotStackObservers` fails. Revert.

- [ ] **Step 6: Run the full suite**

Run: `swift test`
Expected: PASS, 308 tests.

- [ ] **Step 7: Commit**

```bash
git add Sources/CreativeNotchUI/SystemActivityObserver.swift Tests/CreativeNotchUITests/SystemActivityObserverTests.swift
git commit -m "feat: observe sleep and lock, feeding the SystemActivity gate"
```

---

### Task 7: `ClipboardPoller` — the one timer

The project's single admitted timer. Two things make it testable without sleeping: `tick(now:)` carries the entire decision and is called directly by tests, and the timer itself is injected the way `AppDelegate.installOutsideClickMonitor` is.

The behaviour that most needs pinning is **resume**. When the poller is suspended and something is copied, `changeCount` moves. On resume the new count is adopted as the baseline and the content is *never read* — capturing it would mean recording whatever another session or a background process put on the pasteboard while the screen was locked.

**Files:**
- Create: `Sources/CreativeNotchUI/Clipboard/ClipboardPoller.swift`
- Create: `Tests/CreativeNotchUITests/ClipboardPollerTests.swift`

**Interfaces:**
- Consumes: `ClipboardContent`, `ClipboardPollSchedule` (Tasks 2, 4), `SystemActivity` (Task 1), `NSPasteboard.clipboardCapture()` (Task 5).
- Produces:
  - `@MainActor final class ClipboardPoller` with `init(pasteboard: NSPasteboard = .general)`, `var onCapture: ((ClipboardContent) -> Void)?`, `var isLowPowerMode: () -> Bool`, `var scheduleTimer: (TimeInterval, @escaping () -> Void) -> Any?`, `var cancelTimer: (Any) -> Void`, `private(set) var scheduledInterval: TimeInterval?`, `func start(now: TimeInterval)`, `func stop()`, `func setActivity(_ activity: SystemActivity, now: TimeInterval)`, `func tick(now: TimeInterval)`

- [ ] **Step 1: Write the failing tests**

Create `Tests/CreativeNotchUITests/ClipboardPollerTests.swift`:

```swift
import AppKit
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// The project's one admitted timer (spec section 5.3).
///
/// Nothing here sleeps. `tick(now:)` carries the whole decision and is
/// called directly, and the timer is injected the way
/// `AppDelegate.installOutsideClickMonitor` is — so scheduling is asserted
/// by inspecting what the poller *asked* for rather than by waiting.
@MainActor
struct ClipboardPollerTests {

    /// A stand-in for `Timer` that records rather than fires.
    private final class FakeTimer {
        var interval: TimeInterval
        var cancelled = false
        init(interval: TimeInterval) { self.interval = interval }
    }

    private struct Harness {
        let poller: ClipboardPoller
        let pasteboard: NSPasteboard
        let captured: () -> [ClipboardContent]
        let timers: () -> [FakeTimer]
    }

    private func makeHarness(lowPower: Bool = false) -> Harness {
        let pb = NSPasteboard(name: NSPasteboard.Name("CreativeNotchPollTest-\(UUID().uuidString)"))
        pb.clearContents()

        let poller = ClipboardPoller(pasteboard: pb)
        let box = Box()

        poller.isLowPowerMode = { lowPower }
        poller.onCapture = { box.captured.append($0) }
        poller.scheduleTimer = { interval, _ in
            let timer = FakeTimer(interval: interval)
            box.timers.append(timer)
            return timer
        }
        poller.cancelTimer = { ($0 as? FakeTimer)?.cancelled = true }

        return Harness(
            poller: poller,
            pasteboard: pb,
            captured: { box.captured },
            timers: { box.timers }
        )
    }

    private final class Box {
        var captured: [ClipboardContent] = []
        var timers: [FakeTimer] = []
    }

    // MARK: - Capturing

    @Test func aChangedPasteboardIsCaptured() {
        let h = makeHarness()
        h.poller.start(now: 0)
        h.pasteboard.setString("hello", forType: .string)
        h.poller.tick(now: 1)

        #expect(h.captured() == [.text("hello")])
    }

    /// The `changeCount` guard is what makes a 0.75s timer acceptable:
    /// almost every tick does one integer comparison and stops.
    @Test func anUnchangedPasteboardIsNotRead() {
        let h = makeHarness()
        h.pasteboard.setString("hello", forType: .string)
        h.poller.start(now: 0)

        h.poller.tick(now: 1)
        h.poller.tick(now: 2)

        #expect(h.captured().isEmpty)
    }

    /// Starting adopts whatever is already on the pasteboard as the
    /// baseline without capturing it. Launching the app must not sweep in
    /// whatever happened to be copied beforehand.
    @Test func startingDoesNotCaptureWhatWasAlreadyThere() {
        let h = makeHarness()
        h.pasteboard.setString("from before launch", forType: .string)
        h.poller.start(now: 0)
        h.poller.tick(now: 1)

        #expect(h.captured().isEmpty)
    }

    @Test func successiveChangesAreEachCaptured() {
        let h = makeHarness()
        h.poller.start(now: 0)

        h.pasteboard.clearContents()
        h.pasteboard.setString("one", forType: .string)
        h.poller.tick(now: 1)

        h.pasteboard.clearContents()
        h.pasteboard.setString("two", forType: .string)
        h.poller.tick(now: 2)

        #expect(h.captured() == [.text("one"), .text("two")])
    }

    /// A concealed copy is not captured, but it *is* activity. The
    /// back-off measures time since anything changed, so a password
    /// manager copy must reset it — otherwise the poller crawls at the
    /// idle rate exactly when the user is busiest.
    @Test func aRefusedChangeStillCountsAsActivity() {
        let h = makeHarness()
        h.poller.start(now: 0)
        h.poller.tick(now: 300)
        #expect(h.poller.scheduledInterval == ClipboardPollSchedule.idleInterval)

        h.pasteboard.setString("secret", forType: .nsConcealed)
        h.poller.tick(now: 301)

        #expect(h.captured().isEmpty)
        #expect(h.poller.scheduledInterval == ClipboardPollSchedule.activeInterval)
    }

    // MARK: - Suspension

    @Test func aSuspendedPollerCapturesNothing() {
        let h = makeHarness()
        h.poller.start(now: 0)
        h.poller.setActivity(.locked, now: 1)

        h.pasteboard.setString("while locked", forType: .string)
        h.poller.tick(now: 2)

        #expect(h.captured().isEmpty)
    }

    @Test func suspendingCancelsTheTimer() {
        let h = makeHarness()
        h.poller.start(now: 0)
        h.poller.setActivity(.asleep, now: 1)

        #expect(h.poller.scheduledInterval == nil)
        #expect(h.timers().allSatisfy(\.cancelled))
    }

    /// The behaviour this task exists for. Something was copied while the
    /// screen was locked; on unlock the baseline moves forward and that
    /// content is never read.
    @Test func resumingResyncsWithoutCapturing() {
        let h = makeHarness()
        h.poller.start(now: 0)
        h.poller.setActivity(.locked, now: 1)

        h.pasteboard.setString("copied while locked", forType: .string)

        h.poller.setActivity(.active, now: 2)
        h.poller.tick(now: 3)

        #expect(h.captured().isEmpty)
    }

    /// Resuming must not deafen the poller to what comes next.
    @Test func aChangeAfterResumingIsCaptured() {
        let h = makeHarness()
        h.poller.start(now: 0)
        h.poller.setActivity(.locked, now: 1)
        h.pasteboard.setString("copied while locked", forType: .string)
        h.poller.setActivity(.active, now: 2)

        h.pasteboard.clearContents()
        h.pasteboard.setString("copied after unlock", forType: .string)
        h.poller.tick(now: 3)

        #expect(h.captured() == [.text("copied after unlock")])
    }

    @Test func resumingRestartsTheTimer() {
        let h = makeHarness()
        h.poller.start(now: 0)
        h.poller.setActivity(.locked, now: 1)
        h.poller.setActivity(.active, now: 2)

        #expect(h.poller.scheduledInterval == ClipboardPollSchedule.activeInterval)
    }

    /// The resume treats the moment of resuming as the last change, so a
    /// machine that slept for a week does not come back polling at the
    /// idle rate.
    @Test func resumingResetsTheBackOffClock() {
        let h = makeHarness()
        h.poller.start(now: 0)
        h.poller.setActivity(.asleep, now: 1)
        h.poller.setActivity(.active, now: 1_000_000)

        #expect(h.poller.scheduledInterval == ClipboardPollSchedule.activeInterval)
    }

    @Test func anUnchangedActivityDoesNotRebuildTheTimer() {
        let h = makeHarness()
        h.poller.start(now: 0)
        let before = h.timers().count
        h.poller.setActivity(.active, now: 1)

        #expect(h.timers().count == before)
    }

    // MARK: - Scheduling

    @Test func startingSchedulesAtTheActiveRate() {
        let h = makeHarness()
        h.poller.start(now: 0)

        #expect(h.poller.scheduledInterval == ClipboardPollSchedule.activeInterval)
        #expect(h.timers().last?.interval == ClipboardPollSchedule.activeInterval)
    }

    @Test func aQuietSpellBacksTheTimerOff() {
        let h = makeHarness()
        h.poller.start(now: 0)
        h.poller.tick(now: ClipboardPollSchedule.idleAfter + 1)

        #expect(h.poller.scheduledInterval == ClipboardPollSchedule.idleInterval)
        #expect(h.timers().last?.interval == ClipboardPollSchedule.idleInterval)
    }

    @Test func aChangeAfterBackingOffReturnsToTheActiveRate() {
        let h = makeHarness()
        h.poller.start(now: 0)
        h.poller.tick(now: 300)
        #expect(h.poller.scheduledInterval == ClipboardPollSchedule.idleInterval)

        h.pasteboard.setString("something", forType: .string)
        h.poller.tick(now: 301)

        #expect(h.poller.scheduledInterval == ClipboardPollSchedule.activeInterval)
    }

    /// The timer is rebuilt only when the wanted interval actually
    /// changes. Rebuilding on every tick would mean tearing down and
    /// recreating a `Timer` roughly once a second, all day.
    @Test func anUnchangedIntervalDoesNotRebuildTheTimer() {
        let h = makeHarness()
        h.poller.start(now: 0)
        let before = h.timers().count

        h.poller.tick(now: 1)
        h.poller.tick(now: 2)

        #expect(h.timers().count == before)
    }

    @Test func lowPowerModeRaisesTheScheduledInterval() {
        let h = makeHarness(lowPower: true)
        h.poller.start(now: 0)

        #expect(h.poller.scheduledInterval == ClipboardPollSchedule.lowPowerFloor)
    }

    // MARK: - Lifecycle

    @Test func stoppingCancelsTheTimer() {
        let h = makeHarness()
        h.poller.start(now: 0)
        h.poller.stop()

        #expect(h.poller.scheduledInterval == nil)
        #expect(h.timers().allSatisfy(\.cancelled))
    }

    @Test func aStoppedPollerCapturesNothing() {
        let h = makeHarness()
        h.poller.start(now: 0)
        h.poller.stop()

        h.pasteboard.setString("after stop", forType: .string)
        h.poller.tick(now: 1)

        #expect(h.captured().isEmpty)
    }

    @Test func startingTwiceDoesNotStackTimers() {
        let h = makeHarness()
        h.poller.start(now: 0)
        h.poller.start(now: 1)

        #expect(h.timers().count == 2)
        #expect(h.timers().first?.cancelled == true)
        #expect(h.timers().last?.cancelled == false)
    }

    @Test func stoppingWithoutStartingIsHarmless() {
        let h = makeHarness()
        h.poller.stop()
        #expect(h.poller.scheduledInterval == nil)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter ClipboardPollerTests`
Expected: FAIL — `cannot find 'ClipboardPoller' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/CreativeNotchUI/Clipboard/ClipboardPoller.swift`:

```swift
import AppKit
import CreativeNotchCore

/// The project's one timer.
///
/// `NSPasteboard` has no change notification, so this module polls — and
/// spec section 5.3 admits exactly one repeating timer to do it. Everything
/// that makes that defensible is enforced here: the `changeCount` guard so
/// almost every tick is a single integer comparison, the back-off from
/// `ClipboardPollSchedule`, and a hard suspension outside `.active`.
///
/// `tick(now:)` carries the whole decision and takes time as a parameter,
/// so the poll path is tested by calling it rather than by sleeping. The
/// timer is injected for the same reason, following the precedent set by
/// `AppDelegate.installOutsideClickMonitor`.
@MainActor
public final class ClipboardPoller {

    public var onCapture: ((ClipboardContent) -> Void)?

    /// Read at each tick rather than observed. It is a free property read
    /// and it cannot drift out of step the way a cached notification value
    /// can.
    public var isLowPowerMode: () -> Bool = {
        ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    /// Injected so tests can assert what was *asked* for without waiting.
    public var scheduleTimer: (TimeInterval, @escaping () -> Void) -> Any? = { interval, fire in
        Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { fire() }
        }
    }

    public var cancelTimer: (Any) -> Void = { ($0 as? Timer)?.invalidate() }

    /// What the running timer is set to, or `nil` when suspended.
    public private(set) var scheduledInterval: TimeInterval?

    private let pasteboard: NSPasteboard
    private var timer: Any?
    private var lastChangeCount: Int
    private var lastChangeAt: TimeInterval = 0
    private var activity: SystemActivity = .active
    private var isRunning = false

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        self.lastChangeCount = pasteboard.changeCount
    }

    /// Adopts whatever is on the pasteboard now as the baseline, without
    /// capturing it. Launching must not sweep in whatever happened to be
    /// copied beforehand.
    ///
    /// Cancels first, the way `SystemActivityObserver.start()` does, so a
    /// second `start` replaces the timer rather than being swallowed by
    /// `reschedule`'s unchanged-interval guard and leaving the old one
    /// running against a fresh baseline.
    public func start(now: TimeInterval) {
        cancelCurrentTimer()
        isRunning = true
        lastChangeCount = pasteboard.changeCount
        lastChangeAt = now
        reschedule(now: now)
    }

    public func stop() {
        isRunning = false
        cancelCurrentTimer()
    }

    /// The gate. Spec section 4.7: no poller runs outside `.active`.
    ///
    /// Resuming **resyncs without capturing**. While suspended, anything
    /// copied moved `changeCount`; adopting that count as the new baseline
    /// without reading the content is the whole point. Capturing it would
    /// mean recording whatever another session or a background process put
    /// on the pasteboard while the screen was locked — the content this
    /// module has the least claim to.
    ///
    /// `lastChangeAt` is reset to the moment of resuming too, so a machine
    /// that slept for a week does not come back polling at the idle rate.
    public func setActivity(_ activity: SystemActivity, now: TimeInterval) {
        guard activity != self.activity else { return }
        self.activity = activity

        guard activity == .active else {
            cancelCurrentTimer()
            return
        }

        lastChangeCount = pasteboard.changeCount
        lastChangeAt = now
        if isRunning { reschedule(now: now) }
    }

    /// One poll.
    ///
    /// The `changeCount` comparison is what makes a 0.75s timer
    /// defensible: on almost every tick it is a single integer comparison
    /// and nothing else. Reading the pasteboard's *contents* every time
    /// would not be.
    ///
    /// Rescheduling happens on every tick, not only on changed ones. The
    /// back-off exists precisely for the case where nothing is changing,
    /// so returning early on an unchanged count would mean the poller
    /// never reached the code that slows it down — and it would sit at
    /// 0.75s forever.
    public func tick(now: TimeInterval) {
        guard isRunning, activity == .active else { return }

        let count = pasteboard.changeCount
        let changed = count != lastChangeCount

        // The clock is advanced before the capture check, not after. A
        // concealed copy is refused, but it is still activity — and the
        // back-off measures time since anything changed. Leaving the clock
        // alone here would have the poller crawling at the idle rate
        // immediately after a password manager copy, which is exactly when
        // the user is busiest.
        if changed {
            lastChangeCount = count
            lastChangeAt = now
        }

        reschedule(now: now)

        guard changed, let content = pasteboard.clipboardCapture() else { return }
        onCapture?(content)
    }

    // MARK: - Internals

    /// Rebuilds the timer only when the wanted interval actually changes.
    /// Rebuilding unconditionally would tear down and recreate a `Timer`
    /// roughly once a second, all day, for no gain.
    private func reschedule(now: TimeInterval) {
        let wanted = ClipboardPollSchedule.interval(
            sinceLastChange: now - lastChangeAt,
            lowPower: isLowPowerMode()
        )
        guard wanted != scheduledInterval else { return }

        cancelCurrentTimer()
        timer = scheduleTimer(wanted) { [weak self] in
            guard let self else { return }
            self.tick(now: Date().timeIntervalSince1970)
        }
        scheduledInterval = wanted
    }

    private func cancelCurrentTimer() {
        if let timer { cancelTimer(timer) }
        timer = nil
        scheduledInterval = nil
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter ClipboardPollerTests`
Expected: PASS, 21 tests.

- [ ] **Step 5: Prove the tests bite**

In `setActivity`, delete the `lastChangeCount = pasteboard.changeCount` line. Build, run `swift test --filter ClipboardPollerTests`. Expected: `resumingResyncsWithoutCapturing` fails. Revert.

In `tick`, move `reschedule(now: now)` inside the `if changed` block — the natural-looking mistake, and the one that would leave the poller stuck at 0.75s forever. Build, run again. Expected: `aQuietSpellBacksTheTimerOff` fails. Revert.

In `tick`, move the whole `if changed { … }` block to after the `clipboardCapture()` guard. Build, run again. Expected: `aRefusedChangeStillCountsAsActivity` fails. Revert.

In `reschedule`, delete the `guard wanted != scheduledInterval` line. Build, run again. Expected: `anUnchangedIntervalDoesNotRebuildTheTimer` fails. Revert.

In `start`, delete `lastChangeCount = pasteboard.changeCount`. Build, run again. Expected: `startingDoesNotCaptureWhatWasAlreadyThere` fails. Revert.

- [ ] **Step 6: Run the full suite**

Run: `swift test`
Expected: PASS, 329 tests.

- [ ] **Step 7: Commit**

```bash
git add Sources/CreativeNotchUI/Clipboard/ClipboardPoller.swift Tests/CreativeNotchUITests/ClipboardPollerTests.swift
git commit -m "feat: add the gated clipboard poller with idle back-off"
```

---

### Task 8: `ClipboardController` — poller, gate and ring in one place

Mirrors `HUDController`: the observers are dumb sources, and the wiring that connects them lives in one testable object rather than being spread through `AppDelegate`.

**Files:**
- Create: `Sources/CreativeNotchUI/Clipboard/ClipboardController.swift`
- Create: `Tests/CreativeNotchUITests/ClipboardControllerTests.swift`

**Interfaces:**
- Consumes: `ClipboardStore` (Task 3), `ClipboardPoller` (Task 7), `SystemActivityObserver` (Task 6), `NSPasteboard.write(_:)` (Task 5).
- Produces:
  - `@MainActor final class ClipboardController` with `init(store: ClipboardStore, pasteboard: NSPasteboard = .general)`, `let store: ClipboardStore`, `func start()`, `func stop()`, `func paste(_ entry: ClipboardEntry)`, and internal `let poller: ClipboardPoller`, `let activity: SystemActivityObserver`

- [ ] **Step 1: Write the failing tests**

Create `Tests/CreativeNotchUITests/ClipboardControllerTests.swift`:

```swift
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

    private func makeController() -> (ClipboardController, NSPasteboard) {
        let pb = NSPasteboard(name: NSPasteboard.Name("CreativeNotchCtlTest-\(UUID().uuidString)"))
        pb.clearContents()
        let controller = ClipboardController(store: ClipboardStore(), pasteboard: pb)
        controller.poller.scheduleTimer = { _, _ in nil }
        controller.poller.cancelTimer = { _ in }
        controller.poller.isLowPowerMode = { false }
        return (controller, pb)
    }

    @Test func aCapturedChangeReachesTheRing() {
        let (controller, pb) = makeController()
        controller.start()

        pb.setString("captured", forType: .string)
        controller.poller.tick(now: 1)

        #expect(controller.store.entries.map(\.content) == [.text("captured")])
    }

    @Test func lockingTheScreenStopsEntriesReachingTheRing() {
        let (controller, pb) = makeController()
        controller.start()
        controller.activity.handle(.screenLocked)

        pb.setString("while locked", forType: .string)
        controller.poller.tick(now: 1)

        #expect(controller.store.entries.isEmpty)
    }

    /// The gate is wired, not merely present: an unlock has to reach the
    /// poller for polling to resume at all.
    @Test func unlockingResumesCapture() {
        let (controller, pb) = makeController()
        controller.start()
        controller.activity.handle(.screenLocked)
        controller.activity.handle(.screenUnlocked)

        pb.clearContents()
        pb.setString("after unlock", forType: .string)
        controller.poller.tick(now: 2)

        #expect(controller.store.entries.map(\.content) == [.text("after unlock")])
    }

    @Test func stoppingStopsBoth() {
        let (controller, pb) = makeController()
        controller.start()
        controller.stop()

        #expect(controller.activity.tokenCount == 0)

        pb.setString("after stop", forType: .string)
        controller.poller.tick(now: 1)
        #expect(controller.store.entries.isEmpty)
    }

    // MARK: - Paste-back

    @Test func pastingWritesTheEntryToThePasteboard() throws {
        let (controller, pb) = makeController()
        let entry = try #require(controller.store.record(.text("paste me"), now: Date()))

        controller.paste(entry)

        #expect(pb.string(forType: .string) == "paste me")
    }

    /// The paste-back loop, resolved by promotion rather than by a special
    /// case. Writing bumps `changeCount`, the poller sees its own write,
    /// and the entry it finds is the one already at the front — so the
    /// ring keeps one copy, not two.
    @Test func pastingBackDoesNotDuplicateTheEntry() throws {
        let (controller, _) = makeController()
        controller.start()
        controller.store.record(.text("A"), now: Date(timeIntervalSince1970: 0))
        controller.store.record(.text("B"), now: Date(timeIntervalSince1970: 1))

        let a = try #require(controller.store.entries.last)
        controller.paste(a)
        controller.poller.tick(now: 2)

        #expect(controller.store.entries.count == 2)
        #expect(controller.store.entries.first?.content == .text("A"))
        #expect(controller.store.entries.first?.id == a.id)
    }

    @Test func pastingAnImageWritesImageData() throws {
        let (controller, pb) = makeController()
        let data = Data([0x89, 0x50, 0x4E, 0x47])
        let entry = try #require(controller.store.record(.image(data, ext: "png"), now: Date()))

        controller.paste(entry)

        #expect(pb.data(forType: .png) == data)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter ClipboardControllerTests`
Expected: FAIL — `cannot find 'ClipboardController' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/CreativeNotchUI/Clipboard/ClipboardController.swift`:

```swift
import AppKit
import CreativeNotchCore

/// Owns the clipboard module's moving parts and the wiring between them.
///
/// Shaped after `HUDController`: `ClipboardPoller` and
/// `SystemActivityObserver` are dumb sources, and everything that connects
/// them lives here rather than being spread through `AppDelegate`, where
/// it could not be tested.
@MainActor
public final class ClipboardController {

    public let store: ClipboardStore

    /// Internal rather than private so the lifecycle is provable, the way
    /// `HUDController` exposes its three observers.
    let poller: ClipboardPoller
    let activity = SystemActivityObserver()

    private let pasteboard: NSPasteboard

    public init(store: ClipboardStore, pasteboard: NSPasteboard = .general) {
        self.store = store
        self.pasteboard = pasteboard
        self.poller = ClipboardPoller(pasteboard: pasteboard)
    }

    public func start() {
        poller.onCapture = { [weak self] content in
            self?.store.record(content, now: Date())
        }
        activity.onChange = { [weak self] activity in
            self?.poller.setActivity(activity, now: Date().timeIntervalSince1970)
        }
        activity.start()
        poller.start(now: Date().timeIntervalSince1970)
    }

    public func stop() {
        poller.stop()
        activity.stop()
    }

    /// Puts an entry back on the pasteboard. That is the whole action —
    /// see `NSPasteboard.write(_:)` for why there is no keystroke.
    ///
    /// No attempt is made to hide the resulting change from the poller.
    /// The write bumps `changeCount`, the poller reads it back, and
    /// `ClipboardStore.record` promotes the entry that is already there.
    /// One copy, at the front, which is the right answer — reached without
    /// a suppression rule that would have to stay correct forever.
    public func paste(_ entry: ClipboardEntry) {
        pasteboard.write(entry.content)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter ClipboardControllerTests`
Expected: PASS, 7 tests.

- [ ] **Step 5: Prove the tests bite**

Delete the `activity.onChange` assignment in `start()`. Build, run `swift test --filter ClipboardControllerTests`. Expected: `lockingTheScreenStopsEntriesReachingTheRing` and `unlockingResumesCapture` fail. Revert.

Delete `activity.stop()` from `stop()`. Build, run again. Expected: `stoppingStopsBoth` fails. Revert.

- [ ] **Step 6: Run the full suite**

Run: `swift test`
Expected: PASS, 336 tests.

- [ ] **Step 7: Commit**

```bash
git add Sources/CreativeNotchUI/Clipboard/ClipboardController.swift Tests/CreativeNotchUITests/ClipboardControllerTests.swift
git commit -m "feat: wire the clipboard poller, activity gate and ring together"
```

---

### Task 9: `PanelTabBar` and last-tab memory — making the module reachable

Until now the panel had no tab switcher at all: tapping the notch always opened `.open(.shelf)`, and `.open(.clipboard)` fell through to a placeholder label. A clipboard nobody can reach is not a finished module, so the switcher is part of this work.

Only shelf and clipboard are rendered. `Tab.hud` stays in the enum — `PeekArbiterTests` and `AppDelegateTests` already reference it — but HUD history does not exist yet, and a tab that opens onto a placeholder is worse than no tab.

**Files:**
- Create: `Sources/CreativeNotchUI/PanelTabBar.swift`
- Create: `Tests/CreativeNotchUITests/PanelTabBarTests.swift`
- Modify: `Sources/CreativeNotchUI/NotchRootView.swift`

**Interfaces:**
- Consumes: `Tab`, `NotchState` (existing).
- Produces:
  - `Tab.title: String` (extension in `PanelTabBar.swift`)
  - `struct PanelTabBar: View` with `static let visible: [Tab]`, `init(selected:onSelect:)`
  - `AppState.lastOpenTab: Tab` (`private(set)`)

- [ ] **Step 1: Write the failing tests**

Create `Tests/CreativeNotchUITests/PanelTabBarTests.swift`:

```swift
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// The switcher that makes the clipboard reachable at all.
@MainActor
struct PanelTabBarTests {

    /// `.hud` stays in the `Tab` enum — `PeekArbiter` and `AppDelegate`
    /// both reference it — but HUD history does not exist, and a tab that
    /// opens onto a placeholder is worse than no tab.
    @Test func onlyTabsWithContentAreShown() {
        #expect(PanelTabBar.visible == [.shelf, .clipboard])
        #expect(PanelTabBar.visible.contains(.hud) == false)
    }

    @Test func everyVisibleTabHasATitle() {
        for tab in PanelTabBar.visible {
            #expect(tab.title.isEmpty == false)
        }
        #expect(Tab.shelf.title == "Shelf")
        #expect(Tab.clipboard.title == "Clipboard")
    }

    // MARK: - Last-tab memory

    @Test func aFreshStateRemembersTheShelf() {
        #expect(AppState().lastOpenTab == .shelf)
    }

    @Test func openingATabRemembersIt() {
        let state = AppState()
        state.transition(to: .open(.clipboard))

        #expect(state.lastOpenTab == .clipboard)
    }

    /// Closing must not forget. Reopening the panel returns to the tab the
    /// user was last on, which is the entire point of remembering.
    @Test func closingKeepsTheRememberedTab() {
        let state = AppState()
        state.transition(to: .open(.clipboard))
        state.transition(to: .closed)

        #expect(state.lastOpenTab == .clipboard)
    }

    /// A peek is not a tab. HUD peeks fire constantly, and letting one
    /// touch this would reset the user's tab out from under them.
    @Test func peeksDoNotDisturbTheRememberedTab() {
        let state = AppState()
        state.transition(to: .open(.clipboard))
        state.transition(to: .peek(.hud(HUDEvent(kind: .volume(0.5)))))

        #expect(state.lastOpenTab == .clipboard)
    }

    @Test func receivingADropDoesNotDisturbTheRememberedTab() {
        let state = AppState()
        state.transition(to: .open(.clipboard))
        state.transition(to: .receiving)

        #expect(state.lastOpenTab == .clipboard)
    }

    @Test func switchingTabsUpdatesTheMemory() {
        let state = AppState()
        state.transition(to: .open(.clipboard))
        state.transition(to: .open(.shelf))

        #expect(state.lastOpenTab == .shelf)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter PanelTabBarTests`
Expected: FAIL — `cannot find 'PanelTabBar' in scope`.

- [ ] **Step 3: Write `PanelTabBar`**

Create `Sources/CreativeNotchUI/PanelTabBar.swift`:

```swift
import SwiftUI
import CreativeNotchCore

public extension Tab {
    var title: String {
        switch self {
        case .shelf:     return "Shelf"
        case .clipboard: return "Clipboard"
        case .hud:       return "HUD"
        }
    }
}

/// The switcher inside the open panel.
///
/// Before this, tapping the notch always opened the shelf and
/// `.open(.clipboard)` fell through to a placeholder label — so the
/// clipboard was unreachable. A module nobody can open is not finished,
/// which is why the switcher lands with it.
struct PanelTabBar: View {

    /// Only tabs that have something behind them.
    ///
    /// `.hud` stays in the `Tab` enum because `PeekArbiter` and
    /// `AppDelegate` reference it, but HUD history is not built. A tab
    /// that opens onto a placeholder is worse than no tab.
    static let visible: [Tab] = [.shelf, .clipboard]

    let selected: Tab
    let onSelect: (Tab) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Self.visible, id: \.self) { tab in
                Button {
                    onSelect(tab)
                } label: {
                    Text(tab.title)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(tab == selected ? 0.95 : 0.5))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background {
                            RoundedRectangle(cornerRadius: 7)
                                .fill(.white.opacity(tab == selected ? 0.14 : 0))
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 8)
    }
}
```

- [ ] **Step 4: Add last-tab memory to `AppState`**

In `Sources/CreativeNotchUI/NotchRootView.swift`, add the property next to `panelFrame`:

```swift
    /// The tab the panel was last opened on.
    ///
    /// Reopening returns here rather than always to the shelf. Only
    /// `.open` touches it: HUD peeks fire constantly, and letting one
    /// reset the tab would move the panel out from under the user for
    /// reasons they never see.
    public private(set) var lastOpenTab: Tab = .shelf
```

Then, in `transition(to:)`, record it immediately after the equality guard:

```swift
    public func transition(to next: NotchState) {
        guard next != state else { return }
        if case .open(let tab) = next { lastOpenTab = tab }
        state = next
        notify(.state(next))
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter PanelTabBarTests`
Expected: PASS, 8 tests.

- [ ] **Step 6: Prove the tests bite**

Change the `if case .open` line to record on every transition by defaulting to `.shelf`. Build, run `swift test --filter PanelTabBarTests`. Expected: `peeksDoNotDisturbTheRememberedTab` and `closingKeepsTheRememberedTab` fail. Revert.

Add `.hud` to `PanelTabBar.visible`. Build, run again. Expected: `onlyTabsWithContentAreShown` fails. Revert.

- [ ] **Step 7: Run the full suite**

Run: `swift test`
Expected: PASS, 344 tests.

- [ ] **Step 8: Commit**

```bash
git add Sources/CreativeNotchUI/PanelTabBar.swift Sources/CreativeNotchUI/NotchRootView.swift Tests/CreativeNotchUITests/PanelTabBarTests.swift
git commit -m "feat: add the panel tab bar and remember the last open tab"
```

---

### Task 10: `ClipboardView` — what you actually see

The list, its previews, and click-to-copy-back. Rendering is not unit-tested in this project (neither `ShelfView` nor `HUDView` is); what is tested is the pure formatting the view leans on, which is why the preview text is a separate function rather than an inline expression.

**Files:**
- Create: `Sources/CreativeNotchUI/Clipboard/ClipboardView.swift`
- Create: `Tests/CreativeNotchUITests/ClipboardPreviewTests.swift`
- Modify: `Sources/CreativeNotchUI/NotchRootView.swift`

**Interfaces:**
- Consumes: `ClipboardStore`, `ClipboardEntry` (Task 3), `ClipboardController.paste(_:)` (Task 8).
- Produces:
  - `ClipboardPreview.text(for: ClipboardContent) -> String`
  - `ClipboardPreview.maxCharacters: Int`
  - `struct ClipboardView: View` with `init(store:onPaste:)`
  - `AppState.clipboard: ClipboardStore?` and `AppState.onPasteClipboard: ((ClipboardEntry) -> Void)?`

- [ ] **Step 1: Write the failing tests**

Create `Tests/CreativeNotchUITests/ClipboardPreviewTests.swift`:

```swift
import Foundation
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// Views are not unit-tested in this project, so the pure formatting they
/// lean on is pulled out and tested instead.
struct ClipboardPreviewTests {

    @Test func shortTextIsShownWhole() {
        #expect(ClipboardPreview.text(for: .text("hello there")) == "hello there")
    }

    /// A 1 MB entry is legal (spec section 5.3), and the notch is a few
    /// hundred points wide. Truncating here is a display concern only —
    /// the stored entry is untouched, so pasting it back is complete.
    @Test func longTextIsTruncatedForDisplay() {
        let long = String(repeating: "a", count: ClipboardPreview.maxCharacters + 50)
        let preview = ClipboardPreview.text(for: .text(long))

        #expect(preview.count <= ClipboardPreview.maxCharacters + 1)
        #expect(preview.hasSuffix("…"))
    }

    @Test func textExactlyAtTheLimitIsNotTruncated() {
        let exact = String(repeating: "b", count: ClipboardPreview.maxCharacters)
        #expect(ClipboardPreview.text(for: .text(exact)) == exact)
    }

    /// Newlines are collapsed: a copied code block would otherwise render
    /// as one very tall row and push everything else off the panel.
    @Test func newlinesAreCollapsedIntoSpaces() {
        #expect(ClipboardPreview.text(for: .text("one\ntwo\r\nthree")) == "one two three")
    }

    @Test func surroundingWhitespaceIsTrimmed() {
        #expect(ClipboardPreview.text(for: .text("  padded  ")) == "padded")
    }

    @Test func runsOfWhitespaceCollapse() {
        #expect(ClipboardPreview.text(for: .text("a     b")) == "a b")
    }

    /// Images have no text, so the preview describes them instead.
    @Test func imagesAreDescribedBySize() {
        #expect(ClipboardPreview.text(for: .image(Data(repeating: 0, count: 2048), ext: "png")) == "PNG image")
        #expect(ClipboardPreview.text(for: .image(Data(repeating: 0, count: 10), ext: "tiff")) == "TIFF image")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter ClipboardPreviewTests`
Expected: FAIL — `cannot find 'ClipboardPreview' in scope`.

- [ ] **Step 3: Write the view**

Create `Sources/CreativeNotchUI/Clipboard/ClipboardView.swift`:

```swift
import SwiftUI
import CreativeNotchCore

/// How an entry reads in a list a few hundred points wide.
///
/// Pulled out of the view because views are not unit-tested here, and this
/// is the only part of the presentation with a right answer.
enum ClipboardPreview {

    static let maxCharacters = 80

    /// Truncation is a display concern only. The stored entry keeps every
    /// byte, so pasting it back gives the whole thing.
    static func text(for content: ClipboardContent) -> String {
        switch content {
        case .image(_, let ext):
            return "\(ext.uppercased()) image"

        case .text(let string):
            // Collapsed, not just trimmed: a copied code block rendered
            // with its newlines becomes one very tall row and pushes the
            // rest of the list off the panel.
            let collapsed = string
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")

            guard collapsed.count > maxCharacters else { return collapsed }
            return collapsed.prefix(maxCharacters) + "…"
        }
    }
}

/// The clipboard history, and the source of paste-backs.
struct ClipboardView: View {
    let store: ClipboardStore
    let onPaste: (ClipboardEntry) -> Void

    var body: some View {
        if store.entries.isEmpty {
            Text("Nothing copied yet")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(store.entries) { entry in
                        Button {
                            onPaste(entry)
                        } label: {
                            ClipboardRow(entry: entry)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
        }
    }
}

private struct ClipboardRow: View {
    let entry: ClipboardEntry

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.45))
                .frame(width: 14)

            Text(ClipboardPreview.text(for: entry.content))
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .contentShape(.rect)
        .background {
            RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.05))
        }
    }

    private var icon: String {
        switch entry.content {
        case .text:  return "text.alignleft"
        case .image: return "photo"
        }
    }
}
```

- [ ] **Step 4: Render it from `NotchRootView`**

In `Sources/CreativeNotchUI/NotchRootView.swift`, add to `AppState` beside `shelf`:

```swift
    /// Set once at install, like `shelf`. `@ObservationIgnored` because
    /// the store publishes its own changes — it is `@Observable`, so the
    /// view redraws from the store rather than from this reference.
    @ObservationIgnored
    public var clipboard: ClipboardStore?

    /// How the view asks for an entry to be put back on the pasteboard.
    /// A closure rather than a `ClipboardController` reference, so the
    /// view layer never gains a way to start or stop the poller.
    @ObservationIgnored
    public var onPasteClipboard: ((ClipboardEntry) -> Void)?
```

Replace the `overlay` switch's shelf case and `default` with the tabbed body:

```swift
            .overlay {
                switch app.state {
                case .closed:
                    EmptyView()

                case .open(let tab):
                    VStack(spacing: 0) {
                        PanelTabBar(selected: tab) { app.transition(to: .open($0)) }
                        openContent(for: tab)
                    }

                case .receiving:
                    Text("Drop here")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))

                case .peek(.hud(let event)):
                    HUDView(kind: event.kind)

                default:
                    Text(label)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
```

Add the content builder next to `label`:

```swift
    @ViewBuilder
    private func openContent(for tab: Tab) -> some View {
        switch tab {
        case .shelf:
            if let shelf = app.shelf { ShelfView(store: shelf) }
        case .clipboard:
            if let clipboard = app.clipboard {
                ClipboardView(store: clipboard) { entry in
                    app.onPasteClipboard?(entry)
                }
            }
        case .hud:
            // Not built. `PanelTabBar.visible` does not offer this tab, so
            // it is unreachable — but `Tab` is exhaustive and the compiler
            // wants a case.
            EmptyView()
        }
    }
```

Finally, change the tap gesture to reopen on the remembered tab:

```swift
            .onTapGesture {
                // Through the funnel, like every other mutation.
                switch app.state {
                case .open:  app.transition(to: .closed)
                default:     app.transition(to: .open(app.lastOpenTab))
                }
            }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter ClipboardPreviewTests`
Expected: PASS, 7 tests.

- [ ] **Step 6: Prove the tests bite**

Change `text(for:)` to use `trimmingCharacters(in: .whitespacesAndNewlines)` instead of splitting. Build, run `swift test --filter ClipboardPreviewTests`. Expected: `newlinesAreCollapsedIntoSpaces` and `runsOfWhitespaceCollapse` fail. Revert.

Change `collapsed.count > maxCharacters` to `>=`. Build, run again. Expected: `textExactlyAtTheLimitIsNotTruncated` fails. Revert.

- [ ] **Step 7: Run the full suite**

Run: `swift test`
Expected: PASS, 351 tests.

- [ ] **Step 8: Commit**

```bash
git add Sources/CreativeNotchUI/Clipboard/ClipboardView.swift Sources/CreativeNotchUI/NotchRootView.swift Tests/CreativeNotchUITests/ClipboardPreviewTests.swift
git commit -m "feat: render the clipboard history and paste entries back"
```

---

### Task 11: Wire it into the app, the menu bar, and the docs

The last task: lifecycle in `AppDelegate`, a clear item in the menu bar, and the documentation that says the module exists.

`MenuBarController`'s initialiser gains two arguments, so `MenuBarShelfTests` must be updated in the same commit — the build will not compile otherwise.

**Files:**
- Modify: `Sources/CreativeNotchUI/MenuBarController.swift`
- Modify: `Sources/CreativeNotchUI/AppDelegate.swift`
- Modify: `Tests/CreativeNotchUITests/MenuBarShelfTests.swift`
- Modify: `Tests/CreativeNotchCoreTests/CorePurityTests.swift`
- Modify: `README.md`
- Create: `Tests/CreativeNotchUITests/ClipboardWiringTests.swift`

**Interfaces:**
- Consumes: everything above.
- Produces:
  - `MenuBarController.init(onShowOnboarding:onClearShelf:shelfCount:onClearClipboard:clipboardCount:)`
  - `MenuBarController.clearClipboardTitle() -> String`
  - `AppDelegate.clipboard: ClipboardController?` (internal)

- [ ] **Step 1: Write the failing tests**

Create `Tests/CreativeNotchUITests/ClipboardWiringTests.swift`:

```swift
import AppKit
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// That the module is actually connected to the app, rather than merely
/// existing beside it.
@MainActor
struct ClipboardWiringTests {

    /// The same literal `AppDelegateStateFunnelTests` uses.
    private static let notched = ScreenMetrics(
        frame: CGRect(x: 1470, y: 200, width: 1470, height: 956),
        safeAreaTopInset: 38,
        auxiliaryTopLeftWidth: 620,
        auxiliaryTopRightWidth: 620,
        menuBarHeight: 38
    )

    private func makeDelegate() -> AppDelegate {
        let delegate = AppDelegate()
        delegate.growthDelay = .zero
        delegate.shelfDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CreativeNotchClipWiring-\(UUID().uuidString)")
        delegate.install(metrics: Self.notched)
        return delegate
    }

    @Test func installingGivesTheStateAClipboardStore() {
        #expect(makeDelegate().state.clipboard != nil)
    }

    /// The view asks for a paste through this closure. Left unset, every
    /// click in the clipboard list would silently do nothing.
    @Test func installingWiresThePasteHandler() {
        #expect(makeDelegate().state.onPasteClipboard != nil)
    }

    // MARK: - Menu bar

    @Test func theClearItemReportsAnEmptyRing() {
        let controller = MenuBarController(
            onShowOnboarding: {},
            onClearShelf: {},
            shelfCount: { 0 },
            onClearClipboard: {},
            clipboardCount: { 0 }
        )

        #expect(controller.clearClipboardTitle() == "Clipboard is empty")
    }

    @Test func theClearItemCountsTheRing() {
        let controller = MenuBarController(
            onShowOnboarding: {},
            onClearShelf: {},
            shelfCount: { 0 },
            onClearClipboard: {},
            clipboardCount: { 7 }
        )

        #expect(controller.clearClipboardTitle() == "Clear Clipboard (7)")
    }

    @Test func clearingFromTheMenuEmptiesTheRing() {
        let store = ClipboardStore()
        store.record(.text("A"), now: Date())

        let controller = MenuBarController(
            onShowOnboarding: {},
            onClearShelf: {},
            shelfCount: { 0 },
            onClearClipboard: { store.clear() },
            clipboardCount: { store.entries.count }
        )
        controller.clearClipboard()

        #expect(store.entries.isEmpty)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter ClipboardWiringTests`
Expected: FAIL — `extra arguments at positions #4, #5 in call`.

- [ ] **Step 3: Extend `MenuBarController`**

In `Sources/CreativeNotchUI/MenuBarController.swift`, add the stored properties beside their shelf counterparts:

```swift
    private var clearClipboardItem: NSMenuItem?

    private let onClearClipboard: () -> Void
    private let clipboardCount: () -> Int
```

Extend the initialiser:

```swift
    public init(
        onShowOnboarding: @escaping () -> Void,
        onClearShelf: @escaping () -> Void,
        shelfCount: @escaping () -> Int,
        onClearClipboard: @escaping () -> Void,
        clipboardCount: @escaping () -> Int
    ) {
        self.onShowOnboarding = onShowOnboarding
        self.onClearShelf = onClearShelf
        self.shelfCount = shelfCount
        self.onClearClipboard = onClearClipboard
        self.clipboardCount = clipboardCount
    }
```

In `install()`, add the item directly after the shelf's `clear` item and before `menu.addItem(.separator())`:

```swift
        let clearClipboard = NSMenuItem(
            title: clearClipboardTitle(),
            action: #selector(clearClipboard),
            keyEquivalent: ""
        )
        clearClipboard.target = self
        clearClipboard.isEnabled = clipboardCount() > 0
        menu.addItem(clearClipboard)
        self.clearClipboardItem = clearClipboard
```

Add the title helper and action beside the shelf's:

```swift
    /// Read when the menu opens, never polled.
    func clearClipboardTitle() -> String {
        let count = clipboardCount()
        return count == 0 ? "Clipboard is empty" : "Clear Clipboard (\(count))"
    }

    @objc func clearClipboard() {
        onClearClipboard()
    }
```

And refresh it in `menuWillOpen`:

```swift
        clearClipboardItem?.title = clearClipboardTitle()
        clearClipboardItem?.isEnabled = clipboardCount() > 0
```

- [ ] **Step 4: Wire `AppDelegate`**

In `Sources/CreativeNotchUI/AppDelegate.swift`, add the property beside `hud`:

```swift
    private(set) var clipboard: ClipboardController?
```

In `install(metrics:)`, after the shelf is built and assigned to `state.shelf`:

```swift
        // The ring is created here rather than at launch so the wiring
        // path is testable without putting a window on screen, exactly as
        // the shelf is.
        let clipboardStore = ClipboardStore()
        let clipboard = ClipboardController(store: clipboardStore)
        state.clipboard = clipboardStore
        state.onPasteClipboard = { [weak clipboard] entry in clipboard?.paste(entry) }
        self.clipboard = clipboard
```

In `applicationDidFinishLaunching`, extend the menu bar construction and start the controller:

```swift
        let menuBar = MenuBarController(
            onShowOnboarding: { [weak self] in self?.showOnboarding() },
            onClearShelf: { [weak self] in try? self?.shelf?.clear() },
            shelfCount: { [weak self] in self?.shelf?.items.count ?? 0 },
            onClearClipboard: { [weak self] in self?.clipboard?.store.clear() },
            clipboardCount: { [weak self] in self?.clipboard?.store.entries.count ?? 0 }
        )
```

and, beside the HUD start:

```swift
        clipboard?.start()
```

In `applicationWillTerminate`, beside `hud?.stop()`:

```swift
        clipboard?.stop()
```

- [ ] **Step 5: Update `MenuBarShelfTests`**

The three `MenuBarController(...)` constructions in `Tests/CreativeNotchUITests/MenuBarShelfTests.swift` (`theClearItemReportsHowManyAreOnTheShelf`, `anEmptyShelfSaysSo`, `oneItemIsNotPluralised`) each need the two new arguments appended:

```swift
            shelfCount: { 3 },
            onClearClipboard: {},
            clipboardCount: { 0 }
        )
```

Nothing else in that file changes — the shelf assertions are unaffected.

Run: `swift test --filter MenuBarShelfTests`
Expected: PASS, 3 tests.

- [ ] **Step 6: Extend `CorePurityTests`**

The recursion anchors in `theCoreSourcesAreWhereWeThinkTheyAre` name one file per Core subdirectory. `Clipboard/` is a new subdirectory and needs one, or the check could silently stop scanning it exactly the way it once stopped scanning `HUD/` and `Shelf/`.

In `Tests/CreativeNotchCoreTests/CorePurityTests.swift`, extend the assertions:

```swift
        #expect(Self.swiftFiles.count >= 16)

        let names = Set(Self.swiftFiles.map(\.lastPathComponent))
        #expect(names.contains("HUDAttribution.swift"))
        #expect(names.contains("ShelfStore.swift"))
        #expect(names.contains("ClipboardStore.swift"))
```

- [ ] **Step 7: Run the full suite**

Run: `swift test`
Expected: PASS, 356 tests.

- [ ] **Step 8: Prove the wiring tests bite**

Delete `state.onPasteClipboard = ...` from `install`. Build, run `swift test --filter ClipboardWiringTests`. Expected: `installingWiresThePasteHandler` fails. Revert.

Delete `state.clipboard = clipboardStore`. Build, run again. Expected: `installingGivesTheStateAClipboardStore` fails. Revert.

- [ ] **Step 9: Update the documentation**

In `README.md`, change the module table row:

```markdown
| ✅ Clipboard history | Done |
```

Update the test count wherever the README states it, to the number `swift test` actually reports.

In the README's clipboard section (around the "50-entry in-memory ring" line), record what shipped:

```markdown
1. **Clipboard history** — 50-entry in-memory ring, cleared on quit, with
   `ConcealedType` / `TransientType` / `AutoGeneratedType` skipped before
   any content is read. Text and images only; file URLs are left to the
   shelf. Polls at 0.75s, backs off to 3s after two quiet minutes, floors
   at 2s under Low Power Mode, and is fully suspended while the screen is
   locked or the machine is asleep — resuming resyncs without capturing
   what was copied in the meantime.
```

- [ ] **Step 10: Verify the whole thing builds and runs**

Run: `swift build && swift test`
Expected: build succeeds, all tests pass.

- [ ] **Step 11: Commit**

```bash
git add -A
git commit -m "feat: wire clipboard history into the app and the menu bar"
```

---

## Definition of done

- [ ] `swift build` succeeds with no warnings.
- [ ] `swift test` passes; the suite has grown from 221 to roughly 356 tests.
- [ ] `CorePurityTests` passes, and its recursion anchors include `ClipboardStore.swift`.
- [ ] `ClipboardStoreTests.theStoreNeverTouchesTheFileSystem` passes — nothing captured reaches disk.
- [ ] The ring holds at most `ClipboardStore.maxTotalBytes`, verified by `theOldestEntriesAreEvictedToStayUnderBudget`.
- [ ] A full-screen retina screenshot copied to the clipboard is captured, not silently dropped. Verify by hand: ⌘⇧⌃4, select the whole screen, then open the clipboard tab.
- [ ] Every image entry in the ring is PNG — nothing stores raw pasteboard TIFF.
- [ ] Clearing the shelf from the menu bar while the panel is open on the shelf tab visibly empties it (Task 0).
- [ ] No test file references `NSPasteboard.general`.
- [ ] No `Task.sleep` was added to any test.
- [ ] Exactly one repeating timer exists in the codebase, owned by `ClipboardPoller`.
- [ ] Every mutation listed under "Prove the tests bite" was performed, seen to fail, and reverted — with the build confirmed good first.
- [ ] The clipboard tab is reachable from the panel, shows entries, and clicking one puts it back on the pasteboard.
- [ ] The menu bar clears the ring and reports its count.
- [ ] `README.md` marks the module done and states the real test count.
- [ ] Spec section 5.3 matches what was built.

## Deliberately not built

- **HUD history.** Spec section 5 describes the panel as tabbed over "shelf, clipboard, and HUD history", but the HUD is peek-only and has no history to show. `Tab.hud` stays in the enum; `PanelTabBar.visible` does not offer it.
- **Search or keyboard navigation** in the clipboard list. Fifty entries in a notch-sized panel do not need filtering yet.
- **Pinned or favourite entries.** A ring with exemptions is a different data structure; nothing has asked for one.
- **Persistence.** Not deferred — refused. In-memory only is the security property the module is built around.
- **Rich text, RTF, or file promises.** Plain text and raster images only. Anything else is captured as its plain-text representation or not at all.
- **A synthesized paste keystroke.** Would require Accessibility, contradicting spec section 6.
- **Low Power Mode as an observed notification.** Read per tick instead; cheaper than the bookkeeping and it cannot drift.
- **Moving the PNG transcode off the main actor.** It runs there today, at roughly 50–150 ms for a large image. Image copies are rare enough that this should not be visible; if it turns out to be, that is the thing to move, and it needs a measurement first rather than a guess.
- **Downscaling stored images.** The byte budget evicts whole entries instead. A two-tier scheme — full data for the newest few, thumbnails behind them — would hold more history for the same memory, but it is a materially more complex data structure and nothing has asked for it.
