# File Shelf Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Drag a file to the notch to stash it; drag it out somewhere else later. Files are copied, capped at 20, purged after 7 days, and removed to the Trash.

**Architecture:** `ShelfStore` lives in `CreativeNotchCore` and owns every file operation — `FileManager` is Foundation, not AppKit, so the code that can destroy data runs headlessly in CI. `CreativeNotchUI` holds only the dragging destination, the grid, and thumbnail generation. No global event monitor and no permission: AppKit already delivers dragging events to the window under the cursor.

**Tech Stack:** Swift 6.3, SwiftUI, AppKit, QuickLookThumbnailing, Swift Testing, SwiftPM. No third-party dependencies.

**Spec:** `docs/specs/2026-08-22-file-shelf-design.md`

## Global Constraints

- Minimum platform **macOS 26.0**.
- **No third-party dependencies.** Standard library, AppKit, SwiftUI, QuickLookThumbnailing, Swift Testing only.
- **`CreativeNotchCore` must never `import AppKit` or `import SwiftUI`.** `CorePurityTests` enforces this mechanically — it will fail the build.
- **No polling.** No unconditional `Timer`, no global event monitor, no `CVDisplayLink`. This module must add none.
- **`FileManager.removeItem` must not appear anywhere in this module.** Removal is `trashItem`, always. Eviction and purging are automatic and silent; a file whose original was deleted has no other copy.
- **Never mutate `AppState.state` directly.** It is `private(set)`; go through `transition(to:)`. Register observers with `observe`, never replace them.
- `now` is passed as a parameter, never read from a clock inside the store.
- All new types in `CreativeNotchCore` are `public`, `Equatable`, and `Sendable`.
- **Every new test must be proven to fail against the bug it targets** — introduce the bug, watch it fail, revert, confirm it passes. Three tests have shipped in this project that passed with their implementation deleted.
- Conventional commit prefixes (`feat:`, `fix:`, `test:`, `chore:`, `docs:`).

---

### Task 1: Probe whether the drop region is gated by `hitTest`

Spec §6.1. Everything downstream assumes a 620×260 drop zone. If AppKit locates dragging destinations by hit-testing, `PassthroughContainer` returning `nil` outside the visible shape silently collapses that zone to the notch — and it would *look* correct, because dropping on the notch still works.

Two bugs in this project have already had exactly this shape: each piece correct, the assembly wrong, every test green. Settle it before building on it.

**Files:**
- Create: `Tests/CreativeNotchUITests/DropRegionTests.swift`
- Modify (only if the probe says so): `Sources/CreativeNotchUI/PassthroughContainer.swift`

**Interfaces:**
- Consumes: `PassthroughContainer` (internal, `Sources/CreativeNotchUI/PassthroughContainer.swift`), `AppDelegate.install(metrics:)`, `AppDelegate.panel`.
- Produces: a settled answer, and if needed `PassthroughContainer.isReceivingDrag: Bool`.

- [ ] **Step 1: Write a test that asks the question directly**

Create `Tests/CreativeNotchUITests/DropRegionTests.swift`:

```swift
import AppKit
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// Does registering for dragged types give the container a drop region
/// wider than its hit-test region?
///
/// `PassthroughContainer.hitTest` returns nil outside the visible shape so
/// menu bar clicks pass through. If AppKit finds dragging destinations the
/// same way, the drop zone collapses to the notch and still looks correct.
@MainActor
struct DropRegionTests {

    private static let notched = ScreenMetrics(
        frame: CGRect(x: 1470, y: 200, width: 1470, height: 956),
        safeAreaTopInset: 38,
        auxiliaryTopLeftWidth: 620,
        auxiliaryTopRightWidth: 620,
        menuBarHeight: 38
    )

    @Test func theContainerIsRegisteredForFileDrops() throws {
        let delegate = AppDelegate()
        delegate.growthDelay = .zero
        delegate.install(metrics: Self.notched)
        let content = try #require(delegate.panel?.contentView)

        #expect(content.registeredDraggedTypes.contains(.fileURL))
    }

    /// The point that matters: deep in the panel, far outside the closed
    /// notch. Clicks there must pass through; drops there must not.
    @Test func aPointOutsideTheNotchIsStillInsideTheContainerBounds() throws {
        let delegate = AppDelegate()
        delegate.growthDelay = .zero
        delegate.install(metrics: Self.notched)
        let content = try #require(delegate.panel?.contentView)

        let deepInPanel = NSPoint(x: 310, y: 100)
        #expect(content.bounds.contains(deepInPanel))
        #expect(content.hitTest(deepInPanel) == nil)   // clicks pass through
    }
}
```

- [ ] **Step 2: Run it**

Run: `swift test --filter DropRegionTests`
Expected: `theContainerIsRegisteredForFileDrops` FAILS — nothing registers yet. The second test passes.

- [ ] **Step 3: Register the container for dragged types**

In `Sources/CreativeNotchUI/PassthroughContainer.swift`, add to the class:

```swift
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL, .string, .png, .tiff])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }
```

Add `import UniformTypeIdentifiers` if `.fileURL` does not resolve from AppKit alone.

- [ ] **Step 4: Run again**

Run: `swift test --filter DropRegionTests`
Expected: PASS, both.

- [ ] **Step 5: Answer the actual question by hand**

This is the part a unit test cannot settle — it needs a real drag from a real Finder window.

Add a temporary logging destination to `PassthroughContainer`:

```swift
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let p = convert(sender.draggingLocation, from: nil)
        NSLog("CreativeNotch PROBE draggingEntered at \(p) bounds \(bounds)")
        return .copy
    }
```

Then:

```bash
./Scripts/bundle.sh && open dist/CreativeNotch.app
log stream --predicate 'eventMessage CONTAINS "CreativeNotch PROBE"' --style compact
```

Drag a file from Finder toward the notch and **stop well below it** — around 150–200pt down from the top of the screen, horizontally centred. Do not drop.

- **If a line is logged with a y well outside the notch band:** the drop region is bounds-based, the 620×260 zone works, and no fallback is needed. Delete the temporary `draggingEntered` and record the finding.
- **If nothing is logged until the cursor is over the notch itself:** the region is gated by `hitTest`. Apply the fallback in Step 6.

- [ ] **Step 6: Fallback, only if Step 5 says the region is gated**

Give the container a flag that widens hit-testing while a drag is in flight:

```swift
    /// AppKit locates dragging destinations by hit-testing, so the
    /// container has to claim points it would otherwise decline — but only
    /// while a drag is actually in flight, or it would swallow clicks
    /// again.
    private(set) var isReceivingDrag = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        if isReceivingDrag, bounds.contains(point) { return self }
        for subview in subviews.reversed() {
            if let hit = subview.hitTest(point) { return hit }
        }
        return nil
    }
```

`isReceivingDrag` is set in Task 4's `draggingEntered` and cleared in `draggingExited` / `performDragOperation`. Note the circularity this leaves: the flag can only be set once a drag has been detected, so the *first* detection still depends on the notch-sized region. If Step 5 lands here, say so in the report — the spec's 620×260 decision may need revisiting with the human.

- [ ] **Step 7: Record the finding and commit**

Append what you found to `docs/specs/2026-08-22-file-shelf-design.md`, replacing the "⚠️ Unverified" heading in §6.1 with the answer and the evidence.

```bash
git add Sources/CreativeNotchUI/PassthroughContainer.swift \
        Tests/CreativeNotchUITests/DropRegionTests.swift \
        docs/specs/2026-08-22-file-shelf-design.md
git commit -m "feat: register the panel for dragged types, and settle the drop region question"
```

---

### Task 2: `ShelfItem` and `DropPayload`

The two value types the rest of the module is written against. Pure, no I/O.

**Files:**
- Create: `Sources/CreativeNotchCore/Shelf/ShelfItem.swift`
- Create: `Sources/CreativeNotchCore/Shelf/DropPayload.swift`
- Create: `Tests/CreativeNotchCoreTests/DropPayloadTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `ShelfItem(id:url:displayName:addedAt:)` — `public`, `Equatable`, `Sendable`, `Identifiable`
  - `DropPayload` — `.file(URL)`, `.text(String)`, `.image(Data, ext: String)`
  - `DropPayload.suggestedName -> String`

- [ ] **Step 1: Write the failing test**

Create `Tests/CreativeNotchCoreTests/DropPayloadTests.swift`:

```swift
import Foundation
import Testing
@testable import CreativeNotchCore

struct DropPayloadTests {

    @Test func aFileKeepsItsOwnName() {
        let payload = DropPayload.file(URL(fileURLWithPath: "/tmp/Report Q3.pdf"))
        #expect(payload.suggestedName == "Report Q3.pdf")
    }

    @Test func aFileWithNoExtensionKeepsItsName() {
        let payload = DropPayload.file(URL(fileURLWithPath: "/tmp/Makefile"))
        #expect(payload.suggestedName == "Makefile")
    }

    @Test func textGetsAGenericName() {
        #expect(DropPayload.text("hello").suggestedName == "Dropped Text.txt")
    }

    @Test func anImageUsesItsExtension() {
        #expect(DropPayload.image(Data(), ext: "png").suggestedName == "Dropped Image.png")
        #expect(DropPayload.image(Data(), ext: "jpeg").suggestedName == "Dropped Image.jpeg")
    }

    @Test func aShelfItemCarriesItsIdentity() {
        let id = UUID()
        let when = Date(timeIntervalSince1970: 1_000)
        let item = ShelfItem(
            id: id,
            url: URL(fileURLWithPath: "/tmp/a.txt"),
            displayName: "a.txt",
            addedAt: when
        )
        #expect(item.id == id)
        #expect(item.displayName == "a.txt")
        #expect(item.addedAt == when)
    }
}
```

- [ ] **Step 2: Run it**

Run: `swift test --filter DropPayloadTests`
Expected: FAIL — `cannot find 'DropPayload' in scope`.

- [ ] **Step 3: Write the types**

Create `Sources/CreativeNotchCore/Shelf/ShelfItem.swift`:

```swift
import Foundation

/// One thing sitting on the shelf.
///
/// `url` points into the shelf's own storage, never at where the file came
/// from — the original may be moved or deleted freely.
public struct ShelfItem: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let url: URL
    public let displayName: String
    public let addedAt: Date

    public init(id: UUID, url: URL, displayName: String, addedAt: Date) {
        self.id = id
        self.url = url
        self.displayName = displayName
        self.addedAt = addedAt
    }
}
```

Create `Sources/CreativeNotchCore/Shelf/DropPayload.swift`:

```swift
import Foundation

/// What a drag delivered, with AppKit already stripped away.
///
/// The pasteboard is converted at the boundary in `CreativeNotchUI` so the
/// store — and everything that can destroy a file — stays testable
/// headlessly.
public enum DropPayload: Equatable, Sendable {
    case file(URL)
    case text(String)
    case image(Data, ext: String)

    /// The name to write it under, before collision handling.
    public var suggestedName: String {
        switch self {
        case .file(let url):        return url.lastPathComponent
        case .text:                 return "Dropped Text.txt"
        case .image(_, let ext):    return "Dropped Image.\(ext)"
        }
    }
}
```

- [ ] **Step 4: Run it**

Run: `swift test --filter DropPayloadTests`
Expected: PASS — 5 tests.

- [ ] **Step 5: Prove the tests have teeth**

Change `suggestedName`'s `.file` case to `return "Dropped File"`. Run `swift test --filter DropPayloadTests` — `aFileKeepsItsOwnName` and `aFileWithNoExtensionKeepsItsName` must FAIL. Revert; confirm they pass. Report both results.

- [ ] **Step 6: Commit**

```bash
git add Sources/CreativeNotchCore/Shelf Tests/CreativeNotchCoreTests/DropPayloadTests.swift
git commit -m "feat: shelf item and drop payload value types"
```

---

### Task 3: `ShelfStore` — adding, naming, and the 20-item cap

The half that writes files. Tested against real temporary directories, because collisions and extensions are exactly where a fake `FileManager` would diverge from the real one.

**Files:**
- Create: `Sources/CreativeNotchCore/Shelf/ShelfStore.swift`
- Create: `Tests/CreativeNotchCoreTests/ShelfStoreTests.swift`

**Interfaces:**
- Consumes: `ShelfItem`, `DropPayload` from Task 2.
- Produces:
  - `ShelfStore(directory: URL, fileManager: FileManager = .default) throws` — `@MainActor`, `public`
  - `ShelfStore.items: [ShelfItem]` — `public private(set)`, **newest first**
  - `ShelfStore.add(_ payload: DropPayload, now: Date) throws -> ShelfItem` — `@discardableResult`
  - `ShelfStore.remove(_ id: UUID) throws`
  - `ShelfStore.clear() throws`
  - `ShelfStore.capacity` = `20`, `ShelfStore.maxAge` = `7 * 24 * 3600`

- [ ] **Step 1: Write the failing tests**

Create `Tests/CreativeNotchCoreTests/ShelfStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import CreativeNotchCore

/// Tested against real temporary directories rather than a fake
/// `FileManager`: name collisions, extensions and deletion are precisely
/// where a fake diverges from the real thing, and those are the cases that
/// can lose a file.
@MainActor
struct ShelfStoreTests {

    private func makeStore() throws -> (ShelfStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shelf-\(UUID().uuidString)")
        return (try ShelfStore(directory: dir), dir)
    }

    private func makeSourceFile(named name: String, contents: String = "x") throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func aNewStoreIsEmptyAndCreatesItsDirectory() throws {
        let (store, dir) = try makeStore()
        #expect(store.items.isEmpty)
        #expect(FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func addingAFileCopiesItAndLeavesTheOriginalAlone() throws {
        let (store, dir) = try makeStore()
        let source = try makeSourceFile(named: "notes.txt", contents: "hello")

        let item = try store.add(.file(source), now: t0)

        #expect(item.displayName == "notes.txt")
        #expect(item.url.deletingLastPathComponent().path == dir.path)
        #expect(try String(contentsOf: item.url, encoding: .utf8) == "hello")
        #expect(FileManager.default.fileExists(atPath: source.path))  // original untouched
        #expect(store.items.count == 1)
    }

    @Test func theNewestItemIsFirst() throws {
        let (store, _) = try makeStore()
        try store.add(.text("one"), now: t0)
        try store.add(.text("two"), now: t0.addingTimeInterval(1))

        #expect(store.items.count == 2)
        #expect(store.items.first?.addedAt == t0.addingTimeInterval(1))
    }

    @Test func aCollidingNameGetsASuffixRatherThanOverwriting() throws {
        let (store, _) = try makeStore()
        let a = try makeSourceFile(named: "shot.png", contents: "first")
        let b = try makeSourceFile(named: "shot.png", contents: "second")
        let c = try makeSourceFile(named: "shot.png", contents: "third")

        let i1 = try store.add(.file(a), now: t0)
        let i2 = try store.add(.file(b), now: t0)
        let i3 = try store.add(.file(c), now: t0)

        #expect(i1.url.lastPathComponent == "shot.png")
        #expect(i2.url.lastPathComponent == "shot 2.png")
        #expect(i3.url.lastPathComponent == "shot 3.png")
        // Nothing was overwritten.
        #expect(try String(contentsOf: i1.url, encoding: .utf8) == "first")
        #expect(try String(contentsOf: i2.url, encoding: .utf8) == "second")
        #expect(try String(contentsOf: i3.url, encoding: .utf8) == "third")
    }

    @Test func textIsWrittenAsAFile() throws {
        let (store, _) = try makeStore()
        let item = try store.add(.text("some notes"), now: t0)
        #expect(item.url.lastPathComponent == "Dropped Text.txt")
        #expect(try String(contentsOf: item.url, encoding: .utf8) == "some notes")
    }

    @Test func anImageIsWrittenWithItsExtension() throws {
        let (store, _) = try makeStore()
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])
        let item = try store.add(.image(bytes, ext: "png"), now: t0)
        #expect(item.url.lastPathComponent == "Dropped Image.png")
        #expect(try Data(contentsOf: item.url) == bytes)
    }

    @Test func theTwentyFirstItemEvictsTheOldest() throws {
        let (store, _) = try makeStore()
        var first: ShelfItem?
        for i in 0..<20 {
            let item = try store.add(.text("item \(i)"), now: t0.addingTimeInterval(Double(i)))
            if i == 0 { first = item }
        }
        #expect(store.items.count == 20)

        try store.add(.text("one too many"), now: t0.addingTimeInterval(100))

        #expect(store.items.count == 20)
        #expect(store.items.contains { $0.id == first?.id } == false)
        #expect(FileManager.default.fileExists(atPath: first!.url.path) == false)
    }

    @Test func removingTakesItOutOfTheListAndOffDisk() throws {
        let (store, _) = try makeStore()
        let item = try store.add(.text("bye"), now: t0)
        try store.remove(item.id)
        #expect(store.items.isEmpty)
        #expect(FileManager.default.fileExists(atPath: item.url.path) == false)
    }

    @Test func clearingEmptiesEverything() throws {
        let (store, _) = try makeStore()
        for i in 0..<3 { try store.add(.text("\(i)"), now: t0) }
        try store.clear()
        #expect(store.items.isEmpty)
    }

    @Test func theCapAndAgeAreWhatTheSpecSays() {
        #expect(ShelfStore.capacity == 20)
        #expect(ShelfStore.maxAge == 7 * 24 * 3600)
    }
}
```

- [ ] **Step 2: Run them**

Run: `swift test --filter ShelfStoreTests`
Expected: FAIL — `cannot find 'ShelfStore' in scope`.

- [ ] **Step 3: Write the store**

Create `Sources/CreativeNotchCore/Shelf/ShelfStore.swift`:

```swift
import Foundation

/// The shelf's contents and every file operation on them.
///
/// Lives in `CreativeNotchCore` because `FileManager` is Foundation, not
/// AppKit — which puts the code that can destroy a file in the target that
/// runs headlessly in CI.
///
/// `@MainActor` because every caller is: the drop target, the view, and the
/// menu bar item. File I/O on the main actor is acceptable at this scale —
/// twenty items, and disk is touched only on add or remove.
@MainActor
public final class ShelfStore {

    public static let capacity = 20
    public static let maxAge: TimeInterval = 7 * 24 * 3600

    /// Newest first.
    public private(set) var items: [ShelfItem] = []

    private let directory: URL
    private let fileManager: FileManager

    public init(directory: URL, fileManager: FileManager = .default) throws {
        self.directory = directory
        self.fileManager = fileManager
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    @discardableResult
    public func add(_ payload: DropPayload, now: Date) throws -> ShelfItem {
        let destination = uniqueURL(for: payload.suggestedName)

        switch payload {
        case .file(let source):
            try fileManager.copyItem(at: source, to: destination)
        case .text(let string):
            try string.write(to: destination, atomically: true, encoding: .utf8)
        case .image(let data, _):
            try data.write(to: destination, options: .atomic)
        }

        let item = ShelfItem(
            id: UUID(),
            url: destination,
            displayName: destination.lastPathComponent,
            addedAt: now
        )
        items.insert(item, at: 0)
        try evictBeyondCapacity()
        return item
    }

    public func remove(_ id: UUID) throws {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items.remove(at: index)
        try trash(item)
    }

    public func clear() throws {
        let all = items
        items.removeAll()
        for item in all { try trash(item) }
    }

    // MARK: - Internals

    /// Appends " 2", " 3", ... before the extension until the name is free.
    private func uniqueURL(for name: String) -> URL {
        let candidate = directory.appendingPathComponent(name)
        guard fileManager.fileExists(atPath: candidate.path) else { return candidate }

        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        while true {
            let suffixed = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            let url = directory.appendingPathComponent(suffixed)
            if !fileManager.fileExists(atPath: url.path) { return url }
            n += 1
        }
    }

    private func evictBeyondCapacity() throws {
        while items.count > Self.capacity {
            let oldest = items.removeLast()
            try trash(oldest)
        }
    }

    /// Removal is always to the Trash.
    ///
    /// Eviction and purging are automatic and silent. A file dropped here
    /// whose original was later deleted has no other copy, so `removeItem`
    /// would destroy it without the user ever deciding to. `removeItem`
    /// must not appear in this module.
    private func trash(_ item: ShelfItem) throws {
        guard fileManager.fileExists(atPath: item.url.path) else { return }
        try fileManager.trashItem(at: item.url, resultingItemURL: nil)
    }
}
```

- [ ] **Step 4: Run them**

Run: `swift test --filter ShelfStoreTests`
Expected: PASS — 10 tests.

- [ ] **Step 5: Prove the tests have teeth**

Apply each of these to `ShelfStore.swift`, run `swift test --filter ShelfStoreTests`, confirm the named test FAILS, then revert:

| Mutation | Must be caught by |
|---|---|
| `uniqueURL` returns `candidate` unconditionally | `aCollidingNameGetsASuffixRatherThanOverwriting` |
| `items.insert(item, at: 0)` → `items.append(item)` | `theNewestItemIsFirst` |
| `evictBeyondCapacity` body emptied | `theTwentyFirstItemEvictsTheOldest` |
| `trash` body emptied | `removingTakesItOutOfTheListAndOffDisk` |

Report the real output for each. If any mutation is NOT caught, say so plainly rather than claiming success.

- [ ] **Step 6: Commit**

```bash
git add Sources/CreativeNotchCore/Shelf/ShelfStore.swift Tests/CreativeNotchCoreTests/ShelfStoreTests.swift
git commit -m "feat: shelf store with copy, unique naming, and 20-item cap"
```

---

### Task 4: Purging, and loading an existing shelf

Persistence across restarts, and the 7-day sweep.

**Files:**
- Modify: `Sources/CreativeNotchCore/Shelf/ShelfStore.swift`
- Modify: `Tests/CreativeNotchCoreTests/ShelfStoreTests.swift`

**Interfaces:**
- Consumes: everything from Task 3.
- Produces:
  - `ShelfStore.purge(now: Date) throws -> [ShelfItem]` — `@discardableResult`, returns what was removed
  - `ShelfStore.init` now repopulates `items` from the directory's existing contents

- [ ] **Step 1: Write the failing tests**

Append to `Tests/CreativeNotchCoreTests/ShelfStoreTests.swift`, inside the struct:

```swift
    // MARK: - Purging and persistence

    @Test func purgingRemovesItemsOlderThanSevenDays() throws {
        let (store, _) = try makeStore()
        let old = try store.add(.text("ancient"), now: t0)
        let fresh = try store.add(.text("recent"), now: t0.addingTimeInterval(ShelfStore.maxAge))

        let removed = try store.purge(now: t0.addingTimeInterval(ShelfStore.maxAge + 1))

        #expect(removed.count == 1)
        #expect(removed.first?.id == old.id)
        #expect(store.items.map(\.id) == [fresh.id])
        #expect(FileManager.default.fileExists(atPath: old.url.path) == false)
    }

    /// Exactly at the boundary the item survives; a second later it does
    /// not. Without this, `<` and `<=` are indistinguishable.
    @Test func anItemExactlyAtTheAgeLimitSurvives() throws {
        let (store, _) = try makeStore()
        try store.add(.text("borderline"), now: t0)

        #expect(try store.purge(now: t0.addingTimeInterval(ShelfStore.maxAge)).isEmpty)
        #expect(store.items.count == 1)

        #expect(try store.purge(now: t0.addingTimeInterval(ShelfStore.maxAge + 1)).count == 1)
        #expect(store.items.isEmpty)
    }

    @Test func purgingAnEmptyShelfIsHarmless() throws {
        let (store, _) = try makeStore()
        #expect(try store.purge(now: t0).isEmpty)
    }

    @Test func aShelfSurvivesBeingReopened() throws {
        let (store, dir) = try makeStore()
        try store.add(.text("kept"), now: t0)
        try store.add(.text("also kept"), now: t0.addingTimeInterval(1))

        let reopened = try ShelfStore(directory: dir)

        #expect(reopened.items.count == 2)
        #expect(reopened.items.first?.displayName == "Dropped Text 2.txt")
    }

    @Test func reopeningIgnoresFilesThatVanished() throws {
        let (store, dir) = try makeStore()
        let item = try store.add(.text("doomed"), now: t0)
        try FileManager.default.removeItem(at: item.url)   // simulating an outside deletion

        let reopened = try ShelfStore(directory: dir)
        #expect(reopened.items.isEmpty)
    }
```

- [ ] **Step 2: Run them**

Run: `swift test --filter ShelfStoreTests`
Expected: FAIL — `value of type 'ShelfStore' has no member 'purge'`, and `aShelfSurvivesBeingReopened` fails because `init` does not load anything.

- [ ] **Step 3: Add purging and loading**

In `Sources/CreativeNotchCore/Shelf/ShelfStore.swift`, replace the initialiser with:

```swift
    public init(directory: URL, fileManager: FileManager = .default) throws {
        self.directory = directory
        self.fileManager = fileManager
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        items = Self.load(from: directory, fileManager: fileManager)
    }

    /// Rebuilds the list from what is actually on disk.
    ///
    /// The directory is the source of truth: there is no sidecar index to
    /// fall out of step with it, and a file removed from underneath us
    /// simply stops appearing. `addedAt` comes from the file's creation
    /// date, which is what the 7-day purge measures against.
    private static func load(from directory: URL, fileManager: FileManager) -> [ShelfItem] {
        let urls = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return urls.compactMap { url -> ShelfItem? in
            guard let created = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
            else { return nil }
            return ShelfItem(
                id: UUID(),
                url: url,
                displayName: url.lastPathComponent,
                addedAt: created
            )
        }
        .sorted { $0.addedAt > $1.addedAt }
    }
```

And add, after `clear()`:

```swift
    /// Removes anything older than `maxAge`, returning what went.
    ///
    /// Called on launch and after each add — never on a timer. A shelf can
    /// only grow when something is added to it, so nothing needs to watch
    /// it.
    @discardableResult
    public func purge(now: Date) throws -> [ShelfItem] {
        let expired = items.filter { now.timeIntervalSince($0.addedAt) > Self.maxAge }
        guard !expired.isEmpty else { return [] }

        let expiredIDs = Set(expired.map(\.id))
        items.removeAll { expiredIDs.contains($0.id) }
        for item in expired { try trash(item) }
        return expired
    }
```

Finally, purge after each add — in `add(_:now:)`, replace `try evictBeyondCapacity()` with:

```swift
        try evictBeyondCapacity()
        try purge(now: now)
```

- [ ] **Step 4: Run them**

Run: `swift test`
Expected: PASS — the whole suite, 15 `ShelfStoreTests` among them.

- [ ] **Step 5: Prove the tests have teeth**

| Mutation | Must be caught by |
|---|---|
| `> Self.maxAge` → `>= Self.maxAge` | `anItemExactlyAtTheAgeLimitSurvives` |
| `load` returns `[]` | `aShelfSurvivesBeingReopened` |
| `.sorted { $0.addedAt > $1.addedAt }` → `<` | `aShelfSurvivesBeingReopened` |

Report the real output for each. If any is NOT caught, say so.

- [ ] **Step 6: Commit**

```bash
git add Sources/CreativeNotchCore/Shelf/ShelfStore.swift Tests/CreativeNotchCoreTests/ShelfStoreTests.swift
git commit -m "feat: purge shelf items past seven days, and reload on launch"
```

---

### Task 5: Pasteboard conversion

The boundary where AppKit becomes `DropPayload`.

**Files:**
- Create: `Sources/CreativeNotchUI/Shelf/Pasteboard+Drop.swift`
- Create: `Tests/CreativeNotchUITests/PasteboardDropTests.swift`

**Interfaces:**
- Consumes: `DropPayload` from Task 2.
- Produces: `NSPasteboard.dropPayloads() -> [DropPayload]`

- [ ] **Step 1: Write the failing tests**

Create `Tests/CreativeNotchUITests/PasteboardDropTests.swift`:

```swift
import AppKit
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// Converting a real `NSPasteboard` into AppKit-free payloads.
///
/// A named pasteboard is used rather than the general one so the tests
/// cannot disturb the machine's actual clipboard.
@MainActor
struct PasteboardDropTests {

    private func makePasteboard() -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("CreativeNotchTest-\(UUID().uuidString)"))
        pb.clearContents()
        return pb
    }

    @Test func fileURLsBecomeFilePayloads() throws {
        let pb = makePasteboard()
        let a = URL(fileURLWithPath: "/tmp/one.txt")
        let b = URL(fileURLWithPath: "/tmp/two.txt")
        pb.writeObjects([a as NSURL, b as NSURL])

        let payloads = pb.dropPayloads()

        #expect(payloads == [.file(a), .file(b)])
    }

    @Test func plainTextBecomesATextPayload() throws {
        let pb = makePasteboard()
        pb.setString("hello there", forType: .string)

        #expect(pb.dropPayloads() == [.text("hello there")])
    }

    @Test func aFileURLWinsOverTheStringRepresentation() throws {
        // Dragging a file also puts its path on the pasteboard as a string.
        // Taking both would stash the file twice.
        let pb = makePasteboard()
        let url = URL(fileURLWithPath: "/tmp/thing.pdf")
        pb.writeObjects([url as NSURL])
        pb.setString("/tmp/thing.pdf", forType: .string)

        #expect(pb.dropPayloads() == [.file(url)])
    }

    @Test func anEmptyPasteboardYieldsNothing() {
        #expect(makePasteboard().dropPayloads().isEmpty)
    }

    @Test func whitespaceOnlyTextIsIgnored() {
        let pb = makePasteboard()
        pb.setString("   \n  ", forType: .string)
        #expect(pb.dropPayloads().isEmpty)
    }
}
```

- [ ] **Step 2: Run them**

Run: `swift test --filter PasteboardDropTests`
Expected: FAIL — `value of type 'NSPasteboard' has no member 'dropPayloads'`.

- [ ] **Step 3: Write the conversion**

Create `Sources/CreativeNotchUI/Shelf/Pasteboard+Drop.swift`:

```swift
import AppKit
import CreativeNotchCore

public extension NSPasteboard {

    /// What this pasteboard offers the shelf, with AppKit stripped away.
    ///
    /// File URLs are checked first and win outright: dragging a file also
    /// puts its path on the pasteboard as a string, and taking both would
    /// stash the same file twice.
    func dropPayloads() -> [DropPayload] {
        if let urls = readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           !urls.isEmpty {
            return urls.map { .file($0) }
        }

        if let image = readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage,
           let data = image.pngData {
            return [.image(data, ext: "png")]
        }

        if let text = string(forType: .string),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return [.text(text)]
        }

        return []
    }
}

private extension NSImage {
    var pngData: Data? {
        guard let tiff = tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
```

- [ ] **Step 4: Run them**

Run: `swift test --filter PasteboardDropTests`
Expected: PASS — 5 tests.

- [ ] **Step 5: Prove the tests have teeth**

| Mutation | Must be caught by |
|---|---|
| Move the `string(forType:)` block above the URL block | `aFileURLWinsOverTheStringRepresentation` |
| Drop the `trimmingCharacters` guard | `whitespaceOnlyTextIsIgnored` |

Report the real output. If either is NOT caught, say so.

- [ ] **Step 6: Commit**

```bash
git add Sources/CreativeNotchUI/Shelf Tests/CreativeNotchUITests/PasteboardDropTests.swift
git commit -m "feat: convert a pasteboard into AppKit-free drop payloads"
```

---

### Task 6: The dragging destination

Wiring the container to the store and the state machine.

**Files:**
- Modify: `Sources/CreativeNotchUI/PassthroughContainer.swift`
- Modify: `Sources/CreativeNotchUI/AppDelegate.swift`
- Create: `Tests/CreativeNotchUITests/ShelfDropTests.swift`

**Interfaces:**
- Consumes: `ShelfStore` (Tasks 3–4), `NSPasteboard.dropPayloads()` (Task 5), `AppState.transition(to:)`, `NotchState.receiving`, `NotchState.open(.shelf)`.
- Produces:
  - `PassthroughContainer.onDragEntered: () -> Void`
  - `PassthroughContainer.onDragExited: () -> Void`
  - `PassthroughContainer.onDrop: ([DropPayload]) -> Bool`
  - `AppDelegate.shelf: ShelfStore`

- [ ] **Step 1: Write the failing tests**

Create `Tests/CreativeNotchUITests/ShelfDropTests.swift`:

```swift
import AppKit
import Testing
import CreativeNotchCore
@testable import CreativeNotchUI

/// The drop path, driven through the delegate's own callbacks rather than
/// a synthesised `NSDraggingInfo` — which cannot be constructed outside
/// AppKit's own drag machinery.
@MainActor
struct ShelfDropTests {

    private static let notched = ScreenMetrics(
        frame: CGRect(x: 1470, y: 200, width: 1470, height: 956),
        safeAreaTopInset: 38,
        auxiliaryTopLeftWidth: 620,
        auxiliaryTopRightWidth: 620,
        menuBarHeight: 38
    )

    private func makeDelegate() throws -> AppDelegate {
        let delegate = AppDelegate()
        delegate.growthDelay = .zero
        delegate.shelfDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shelf-\(UUID().uuidString)")
        delegate.install(metrics: Self.notched)
        return delegate
    }

    @Test func aDragEnteringOpensTheDropTarget() throws {
        let delegate = try makeDelegate()
        let container = try #require(delegate.panel?.contentView as? PassthroughContainer)

        container.onDragEntered()

        #expect(delegate.state.state == .receiving)
    }

    @Test func aDragLeavingClosesIt() throws {
        let delegate = try makeDelegate()
        let container = try #require(delegate.panel?.contentView as? PassthroughContainer)

        container.onDragEntered()
        container.onDragExited()

        #expect(delegate.state.state == .closed)
    }

    @Test func droppingStoresTheItemAndOpensTheShelf() throws {
        let delegate = try makeDelegate()
        let container = try #require(delegate.panel?.contentView as? PassthroughContainer)

        container.onDragEntered()
        let accepted = container.onDrop([.text("stashed")])

        #expect(accepted)
        #expect(delegate.state.state == .open(.shelf))
        #expect(delegate.shelf.items.count == 1)
        #expect(delegate.shelf.items.first?.displayName == "Dropped Text.txt")
    }

    @Test func droppingNothingIsRefusedAndClosesUp() throws {
        let delegate = try makeDelegate()
        let container = try #require(delegate.panel?.contentView as? PassthroughContainer)

        container.onDragEntered()
        let accepted = container.onDrop([])

        #expect(accepted == false)
        #expect(delegate.state.state == .closed)
        #expect(delegate.shelf.items.isEmpty)
    }

    /// Spec section 9: a drop whose files cannot be written is refused,
    /// not half-completed. A read-only directory is the cheapest way to
    /// make every write fail.
    @Test func aDropThatCannotBeStoredIsRefused() throws {
        let delegate = try makeDelegate()
        let container = try #require(delegate.panel?.contentView as? PassthroughContainer)

        // Make the shelf directory unwritable after the store opened it.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: delegate.shelfDirectory.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: delegate.shelfDirectory.path)
        }

        container.onDragEntered()
        let accepted = container.onDrop([.text("cannot be written")])

        #expect(accepted == false)
        #expect(delegate.state.state == .closed)
        #expect(delegate.shelf.items.isEmpty)
    }

    /// A drag in flight must outlive the cursor leaving the notch, or the
    /// drop can never land. The foundation guards this; confirm the shelf
    /// does not undo it.
    @Test func aMouseExitDuringADropDoesNotTearDownTheTarget() throws {
        let delegate = try makeDelegate()
        let container = try #require(delegate.panel?.contentView as? PassthroughContainer)

        container.onDragEntered()
        delegate.hoverView?.onExit()

        #expect(delegate.state.state == .receiving)
    }
}
```

- [ ] **Step 2: Run them**

Run: `swift test --filter ShelfDropTests`
Expected: FAIL — no `shelfDirectory`, no `onDragEntered`.

- [ ] **Step 3: Give the container its drag callbacks**

In `Sources/CreativeNotchUI/PassthroughContainer.swift`, add to the class:

```swift
    var onDragEntered: () -> Void = {}
    var onDragExited: () -> Void = {}
    var onDrop: ([DropPayload]) -> Bool = { _ in false }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        onDragEntered()
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onDragExited()
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        onDrop(sender.draggingPasteboard.dropPayloads())
    }
```

Add `import CreativeNotchCore` at the top of the file.

- [ ] **Step 4: Wire it in the delegate**

In `Sources/CreativeNotchUI/AppDelegate.swift`, add these stored properties:

```swift
    /// Overridable so tests do not write into the real Application Support.
    var shelfDirectory: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("CreativeNotch/Shelf")

    private(set) var shelf: ShelfStore!
```

In `install(metrics:)`, immediately after `let container = PassthroughContainer(...)`:

```swift
        // Purged on launch and after each add — never on a timer.
        shelf = try? ShelfStore(directory: shelfDirectory)
        try? shelf?.purge(now: Date())

        container.onDragEntered = { [weak self] in
            self?.state.transition(to: .receiving)
        }
        container.onDragExited = { [weak self] in
            self?.state.transition(to: .closed)
        }
        container.onDrop = { [weak self] payloads in
            guard let self, let shelf = self.shelf, !payloads.isEmpty else {
                self?.state.transition(to: .closed)
                return false
            }

            // Spec section 9: a write that fails refuses the drop rather
            // than half-completing it. Swallowing the error and opening
            // the shelf anyway would show the user an empty shelf and no
            // reason why.
            var stored = 0
            for payload in payloads {
                do {
                    try shelf.add(payload, now: Date())
                    stored += 1
                } catch {
                    NSLog("CreativeNotch: shelf could not store a drop: \(error)")
                }
            }

            guard stored > 0 else {
                self.state.transition(to: .closed)
                return false
            }
            self.state.transition(to: .open(.shelf))
            return true
        }
```

- [ ] **Step 5: Run them**

Run: `swift test`
Expected: PASS — the whole suite.

- [ ] **Step 6: Prove the tests have teeth**

| Mutation | Must be caught by |
|---|---|
| `onDragEntered` transitions to `.open(.shelf)` instead of `.receiving` | `aDragEnteringOpensTheDropTarget` |
| `onDrop` returns `true` for an empty payload list | `droppingNothingIsRefusedAndClosesUp` |
| `onDrop` skips `shelf.add` | `droppingStoresTheItemAndOpensTheShelf` |
| `guard stored > 0` removed | `aDropThatCannotBeStoredIsRefused` |

Report the real output. If any is NOT caught, say so.

- [ ] **Step 7: Commit**

```bash
git add Sources/CreativeNotchUI Tests/CreativeNotchUITests/ShelfDropTests.swift
git commit -m "feat: accept drops into the shelf from the panel"
```

---

### Task 7: The shelf view, thumbnails, and dragging out

The visible half. Verified by hand — a human is needed to drag a real file.

**Files:**
- Create: `Sources/CreativeNotchUI/Shelf/ShelfThumbnails.swift`
- Create: `Sources/CreativeNotchUI/Shelf/ShelfView.swift`
- Modify: `Sources/CreativeNotchUI/NotchRootView.swift`

**Interfaces:**
- Consumes: `ShelfStore`, `ShelfItem`, `AppState`.
- Produces: `ShelfView(store:)`, `ShelfThumbnails.image(for:size:) async -> NSImage`

- [ ] **Step 1: Write the thumbnail provider**

Create `Sources/CreativeNotchUI/Shelf/ShelfThumbnails.swift`:

```swift
import AppKit
import QuickLookThumbnailing

/// QuickLook previews with a file-icon fallback.
///
/// The cache needs no eviction policy of its own: the shelf holds at most
/// twenty items, so it is bounded by the store.
@MainActor
final class ShelfThumbnails {

    static let shared = ShelfThumbnails()
    private var cache: [URL: NSImage] = [:]

    func cached(for url: URL) -> NSImage? { cache[url] }

    /// The system icon, which is correct for every file type including
    /// folders and app bundles. Available immediately, unlike a preview.
    func icon(for url: URL) -> NSImage {
        NSWorkspace.shared.icon(forFile: url.path)
    }

    func thumbnail(for url: URL, size: CGSize) async -> NSImage {
        if let hit = cache[url] { return hit }

        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: 2,
            representationTypes: .thumbnail
        )

        if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            let image = rep.nsImage
            cache[url] = image
            return image
        }

        let fallback = icon(for: url)
        cache[url] = fallback
        return fallback
    }

    func forget(_ url: URL) { cache[url] = nil }
}
```

- [ ] **Step 2: Write the view**

Create `Sources/CreativeNotchUI/Shelf/ShelfView.swift`:

```swift
import SwiftUI
import CreativeNotchCore

/// The shelf's contents, and the source of drags back out.
///
/// Items carry their real file URL, so any drop target accepts them —
/// Finder, an upload field, another app.
struct ShelfView: View {
    let store: ShelfStore

    private let itemSize = CGSize(width: 64, height: 64)

    var body: some View {
        if store.items.isEmpty {
            Text("Drag files here")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(store.items) { item in
                        ShelfItemView(item: item, size: itemSize)
                            .draggable(item.url)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }
}

private struct ShelfItemView: View {
    let item: ShelfItem
    let size: CGSize

    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 4) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(nsImage: ShelfThumbnails.shared.icon(for: item.url))
                        .resizable().aspectRatio(contentMode: .fit)
                }
            }
            .frame(width: size.width, height: size.height)

            Text(item.displayName)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: size.width + 16)
        }
        .task {
            image = await ShelfThumbnails.shared.thumbnail(for: item.url, size: size)
        }
    }
}
```

- [ ] **Step 3: Show it in the panel**

In `Sources/CreativeNotchUI/NotchRootView.swift`, `AppState` gains:

```swift
    /// Set once at install. Not `@Observable`-tracked state — the store
    /// publishes its own changes.
    @ObservationIgnored
    public var shelf: ShelfStore?
```

And in `NotchRootView`, replace the `overlay` contents so `.open(.shelf)` renders the shelf:

```swift
            .overlay {
                switch app.state {
                case .closed:
                    EmptyView()
                case .open(.shelf):
                    if let shelf = app.shelf {
                        ShelfView(store: shelf)
                    }
                case .receiving:
                    Text("Drop here")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                default:
                    Text(label)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
```

In `AppDelegate.install(metrics:)`, after creating the store, add `state.shelf = shelf`.

- [ ] **Step 4: Build and check the suite still passes**

Run: `swift build && swift test`
Expected: build clean, whole suite green.

- [ ] **Step 5: Verify by hand — this needs a human**

```bash
pkill -f CreativeNotch; ./Scripts/bundle.sh && open dist/CreativeNotch.app
```

Check, and report exactly what you observed rather than what should happen:

1. Drag a file from Finder toward the notch — the panel opens showing "Drop here".
2. Drop it — the panel shows the shelf with a thumbnail and the filename.
3. Drag that item out to the Desktop — a copy lands there.
4. Drag in an image from a browser — it appears as `Dropped Image.png`.
5. Select text in any app and drag it in — `Dropped Text.txt`.
6. Quit and relaunch — the items are still there.
7. Menu bar clicks either side of the notch still work.

**You cannot see the screen. Do not claim any of these were verified.** List them for the human and say plainly which were not checked.

- [ ] **Step 6: Commit**

```bash
git add Sources/CreativeNotchUI
git commit -m "feat: shelf view with thumbnails and drag-out"
```

---

### Task 8: Menu bar clearing, and documentation

**Files:**
- Modify: `Sources/CreativeNotchUI/MenuBarController.swift`
- Modify: `Sources/CreativeNotchUI/AppDelegate.swift`
- Modify: `README.md`, `docs/ARCHITECTURE.md`, `docs/DEVELOPMENT.md`
- Create: `Tests/CreativeNotchUITests/MenuBarShelfTests.swift`

**Interfaces:**
- Consumes: `ShelfStore.clear()`, `MenuBarController`.
- Produces: `MenuBarController(onShowOnboarding:onClearShelf:shelfCount:)`

- [ ] **Step 1: Write the failing test**

Create `Tests/CreativeNotchUITests/MenuBarShelfTests.swift`:

```swift
import AppKit
import Testing
@testable import CreativeNotchUI

@MainActor
struct MenuBarShelfTests {

    @Test func theClearItemReportsHowManyAreOnTheShelf() {
        var cleared = false
        let controller = MenuBarController(
            onShowOnboarding: {},
            onClearShelf: { cleared = true },
            shelfCount: { 3 }
        )
        #expect(controller.clearShelfTitle() == "Clear Shelf (3)")
        controller.clearShelf()
        #expect(cleared)
    }

    @Test func anEmptyShelfSaysSo() {
        let controller = MenuBarController(
            onShowOnboarding: {},
            onClearShelf: {},
            shelfCount: { 0 }
        )
        #expect(controller.clearShelfTitle() == "Shelf is empty")
    }
}
```

- [ ] **Step 2: Run it**

Run: `swift test --filter MenuBarShelfTests`
Expected: FAIL — the initialiser takes only one argument.

- [ ] **Step 3: Extend the controller**

In `Sources/CreativeNotchUI/MenuBarController.swift`, replace the stored properties and initialiser with:

```swift
    private let onShowOnboarding: () -> Void
    private let onClearShelf: () -> Void
    private let shelfCount: () -> Int

    public init(
        onShowOnboarding: @escaping () -> Void,
        onClearShelf: @escaping () -> Void,
        shelfCount: @escaping () -> Int
    ) {
        self.onShowOnboarding = onShowOnboarding
        self.onClearShelf = onClearShelf
        self.shelfCount = shelfCount
        super.init()
    }
```

Add these methods:

```swift
    /// Read when the menu opens, never polled.
    func clearShelfTitle() -> String {
        let count = shelfCount()
        return count == 0 ? "Shelf is empty" : "Clear Shelf (\(count))"
    }

    @objc func clearShelf() { onClearShelf() }
```

Store the new item so its title can be refreshed, alongside the existing `accessibilityItem`:

```swift
    private var clearShelfItem: NSMenuItem?
```

In `install()`, add it above the separator:

```swift
        let clear = NSMenuItem(
            title: clearShelfTitle(),
            action: #selector(clearShelf),
            keyEquivalent: ""
        )
        clear.target = self
        clear.isEnabled = shelfCount() > 0
        menu.addItem(clear)
        clearShelfItem = clear
```

In `menuWillOpen`, refresh it beside the Accessibility item:

```swift
        clearShelfItem?.title = clearShelfTitle()
        clearShelfItem?.isEnabled = shelfCount() > 0
```

Then update the call site in `AppDelegate.applicationDidFinishLaunching`, which currently passes a single trailing closure:

```swift
        let menuBar = MenuBarController(
            onShowOnboarding: { [weak self] in self?.showOnboarding() },
            onClearShelf: { [weak self] in try? self?.shelf?.clear() },
            shelfCount: { [weak self] in self?.shelf?.items.count ?? 0 }
        )
```

- [ ] **Step 4: Run it**

Run: `swift test`
Expected: PASS — whole suite.

- [ ] **Step 5: Update the documentation**

- `README.md`: add the shelf to the built column of the status table and move it out of the roadmap; update the test count and the usage table with drag-in and drag-out.
- `docs/ARCHITECTURE.md`: a short section on the shelf — where the store lives and why (`FileManager` is Foundation), that removal is always `trashItem`, that purging happens on launch and after each add rather than on a timer, and whatever Task 1 settled about the drop region.
- `docs/DEVELOPMENT.md`: note that shelf tests write to temporary directories, and that `ShelfStore` takes `now` as a parameter.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: clear the shelf from the menu bar, and document the module"
```

---

## Definition of done

- `swift test` green; CI green on the branch.
- Dropping a file, an image, and text all land on the shelf.
- Dragging an item out produces a copy at the destination.
- The shelf survives a relaunch; items past 7 days are gone.
- Removal puts files in the Trash — confirmed by looking in the Trash.
- Menu bar clicks either side of the notch still work.
- No `Timer`, no global event monitor, no `removeItem` anywhere in the module.
- `CorePurityTests` still passes: no AppKit or SwiftUI in `CreativeNotchCore`.

## Deliberately not built

Click to open, click to reveal, context menus, sharing, nested folders, tagging. Drag-out is the whole contract.
