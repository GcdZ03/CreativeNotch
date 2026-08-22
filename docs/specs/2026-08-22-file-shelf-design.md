# File Shelf — Design

**Date:** 2026-08-22
**Status:** Approved design, pre-implementation
**Target:** macOS 26+, builds on the completed foundation
**Supersedes:** section 5.2 of `2026-08-22-creativenotch-design.md`

## 1. Purpose

Drag a file to the notch to stash it; drag it out somewhere else later. The
staging area for the "I need to move this between two windows" problem that
otherwise means a desktop full of transient files.

This is the first module. It was chosen ahead of the HUD because the HUD's
suppression half has no known solution on macOS 26 — see
[`../research/2026-08-22-hud-feasibility.md`](../research/2026-08-22-hud-feasibility.md).

## 2. Decisions

| Question | Decision |
|---|---|
| Drag trigger | **No monitoring.** Reacts only when a drag arrives at the panel |
| Drop zone | The whole panel rect, 620×260 |
| Accepts | Files and folders, plus text and images (written to files) |
| Getting things out | Drag out to anywhere. No click behaviours |
| Storage | Copy into shelf storage; the original may be moved or deleted freely |
| Capacity | 20 items, oldest evicted |
| Persistence | Survives restarts; items older than 7 days are purged |
| Removal | **`FileManager.trashItem`**, never `removeItem` |
| Item appearance | QuickLook thumbnail where possible, file icon otherwise |
| Permissions | **None.** No Accessibility, no monitoring, nothing at idle |

## 3. Why there is no drag monitor

The original spec planned a global mouse monitor, installed lazily, to
expand the notch the moment a drag began anywhere on screen.

That is not needed. AppKit already delivers dragging events to the window
under the cursor, for free — so a drag that arrives at the panel announces
itself with no monitoring, no permission, and nothing running at idle. The
cost is that the shelf does not open until the drag reaches it, which the
620×260 drop zone makes a large enough target to be practical.

This keeps the project's one architectural rule intact: **the file shelf
adds no subsystem that runs when it is not needed.**

## 4. Where the code lives

```
Sources/CreativeNotchCore/Shelf/
  ShelfItem.swift        value type — id, url, displayName, addedAt
  DropPayload.swift      .file(URL) / .text(String) / .image(Data, ext:)
  ShelfStore.swift       add, evict, purge, remove, clear
Sources/CreativeNotchUI/Shelf/
  ShelfDropTarget.swift  NSDraggingDestination
  ShelfView.swift        the grid, and drag-out
  ShelfThumbnails.swift  QuickLook with an NSWorkspace fallback
  Pasteboard+Drop.swift  NSPasteboard -> [DropPayload]
```

`FileManager` is Foundation, not AppKit, so **everything that can destroy
your data lives in the target that runs headlessly in CI.** Only thumbnail
generation and file icons need `CreativeNotchUI`.

## 5. The store

```swift
public struct ShelfItem: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let url: URL
    public let displayName: String
    public let addedAt: Date
}

@MainActor
public final class ShelfStore {
    public static let capacity = 20
    public static let maxAge: TimeInterval = 7 * 24 * 3600

    /// Newest first.
    public private(set) var items: [ShelfItem]

    public init(directory: URL, fileManager: FileManager = .default) throws

    @discardableResult
    public func add(_ payload: DropPayload, now: Date) throws -> ShelfItem

    /// Returns what it removed, so a caller can report it.
    @discardableResult
    public func purge(now: Date) throws -> [ShelfItem]

    public func remove(_ id: UUID) throws
    public func clear() throws
}
```

`now` is a **parameter, not a clock read** — the same pattern as
`PeekArbiter.content(now:)`. It is what makes the 7-day purge testable
without waiting a week, and it must not be replaced with `Date()`.

Storage directory: `~/Library/Application Support/CreativeNotch/Shelf/`.

`@MainActor` because every caller is: the drop target, the view, and the
menu bar item. File I/O on the main actor is acceptable at this scale — a
shelf holds twenty items and only touches disk when one is added or
removed. If a large file ever makes a drop feel slow, the copy is the part
to move off, not the store.

### 5.1 Naming

- Files keep their original name. On collision, ` 2`, ` 3`, … before the
  extension.
- Text becomes `Dropped Text.txt`, images `Dropped Image.png`, with the same
  collision rule.

### 5.2 Removal always goes to the Trash

Eviction and purging are **automatic and silent**. A file dropped here whose
original was later deleted has no other copy, so `removeItem` would destroy
it without the user ever deciding to.

`FileManager.trashItem` costs one call, makes every removal recoverable, and
puts the file where a Mac user already looks. **`removeItem` must not appear
in this module.**

### 5.3 When purging happens

On launch, and after each add. **No timer.** A shelf can only grow when
something is added to it, so nothing needs to watch it.

## 6. The drop target

The panel's `PassthroughContainer` registers for dragged types and
implements `NSDraggingDestination`:

| Event | Effect |
|---|---|
| `draggingEntered` | transition to `.receiving`, return `.copy` |
| `draggingExited` | transition to `.closed` |
| `performDragOperation` | convert the pasteboard, add to the store, transition to `.open(.shelf)` |

`draggingExited` returns to `.closed` rather than to whatever preceded the
drag. Restoring the prior state would mean remembering it across an
interaction the user may have abandoned halfway, and a drag that leaves the
panel is a clear signal the shelf is not wanted — `.closed` is both simpler
and less surprising.

`.receiving` already exists and is already protected: it survives a mouse
exit, and both outside-click and app-switch dismissal skip it. The
foundation built those guards for this module before it existed.

### 6.1 The drop region is gated by `hitTest` — settled 2026-08-22

**Answered by probe, not assumed.** A temporary `draggingEntered` writing
to a file, with real drags from Finder:

```
draggingEntered at x=331 y=235   (bounds 620x260)
draggingEntered at x=388 y=236
draggingEntered at x=334 y=238
draggingEntered at x=346 y=233
```

The closed notch occupies panel-local y 222–260. **Every event landed
inside that band.** Drags deliberately held 150–200pt lower produced
nothing at all. AppKit locates dragging destinations by hit-testing, so
`PassthroughContainer` returning `nil` outside the visible shape bounds the
drop region to exactly what is drawn.

Had this been assumed rather than probed, dropping *on* the notch would
have worked perfectly and the 620×260 zone would have been quietly
fictional — the same shape as the two bugs this project has already
shipped.

### 6.2 What this means for the interaction

The drop region follows the drawn shape, and `.receiving` draws at the full
620×260. So:

**Aim at the notch to open the shelf, then drop anywhere in the panel that
opens.** Precision is needed to *acquire*, not to *drop*, and the acquire
target is the notch the user is already aiming at.

No global monitor, no permission, nothing running at idle — the design's
central constraint survives intact.

### 6.3 `.receiving` bypasses the growth lag

`AppDelegate` normally trails growth of the accepted region by the expand
animation, so a click is never accepted on something not yet drawn.

**`.receiving` is exempt.** During a drag there is no click to mis-accept,
and because the drop region is hit-test-gated, lagging would refuse drops
for a third of a second — exactly as the cursor moves into the panel it
just opened. Every other state keeps the lag.

## 7. Getting things out

Items are draggable via `NSItemProvider` carrying the real file URL, so any
drop target accepts them — Finder, an upload field, another app.

No click-to-open, no click-to-reveal, no context menu. Drag-out is the whole
contract.

## 8. Thumbnails

`QLThumbnailGenerator`, asynchronous, cached by URL. Falls back to
`NSWorkspace.shared.icon(forFile:)`, which is correct for every file type
including folders and app bundles. The cache is bounded by the 20-item cap,
so it needs no eviction policy of its own.

## 9. Error handling

- **A write fails** — the item is not added. The drop is refused rather than
  half-completed.
- **`trashItem` fails** — the item stays in the shelf. Never fall back to
  `removeItem`.
- **The storage directory is missing** — recreated on launch. An item whose
  file has vanished underneath us is dropped from the list.

## 10. Testing

`ShelfStore` against real temporary directories, with an injected clock:

- name collisions, including three files of the same name
- eviction order at the 20-item boundary
- purge at exactly 7 days, either side
- that removal trashes rather than deletes
- that a failed write leaves no partial entry

Pasteboard conversion is tested in `CreativeNotchUITests`. Thumbnails and
the feel of dragging are verified by hand.

Every new test must be shown to fail against the bug it targets — introduce
it, watch the test fail, revert. Three tests have shipped in this project
that passed with their implementation deleted.

## 11. Non-goals

- Click to open, click to reveal, context menus
- Sharing, cloud upload, AirDrop
- Nested folders or tagging inside the shelf
- Any global event monitor
- `removeItem` anywhere in this module
